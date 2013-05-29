{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# language LambdaCase #-}

module CO4.Algorithms.Eitherize
  (eitherize)
where

import           Control.Monad.Reader
import           Control.Monad.Writer
import           Data.List (find)
import qualified Language.Haskell.TH as TH
import           CO4.Language
import           CO4.Util
import           CO4.THUtil
import           CO4.Names 
import           CO4.Algorithms.THInstantiator
import           CO4.Algorithms.Collector
import           CO4.Unique
import           CO4.Algorithms.Eitherize.Names
import           CO4.Algorithms.Eitherize.DecodeInstance (decodeInstance)
import           CO4.Algorithms.Eitherize.EncodeableInstance (encodeableInstance)
import           CO4.Algorithms.Eitherize.EncEqInstance (encEqInstance)
import           CO4.EncodedAdt 
  (isBottom,encodedConstructor,caseOf,constructorArgument)
import           CO4.Algorithms.HindleyMilner (schemes,schemeOfExp)
import           CO4.Cache (CacheKey (..),withCache)
import           CO4.Allocator (known)
import           CO4.Profiling (traced)
import           CO4.EncEq (encEq)

newtype AdtInstantiator u a = AdtInstantiator 
  { runAdtInstantiator :: WriterT [TH.Dec] u a } 
  deriving (Monad, MonadWriter [TH.Dec], MonadUnique)

instance MonadUnique u => MonadCollector (AdtInstantiator u) where

  collectAdt adt = do
    forM_ (zip [0..] $ dAdtConstructors adt) $ \constructor -> do
      mkAllocator constructor
      mkEncodedConstructor constructor

    decodeInstance adt     >>= tellOne
    encodeableInstance adt >>= tellOne
    encEqInstance adt      >>= tellOne

    where 
      mkAllocator          = withConstructor allocatorName   id      'known
      mkEncodedConstructor = withConstructor encodedConsName returnE 'encodedConstructor

      withConstructor bindTo returnE callThis (i,CCon name args) = do
        paramNames <- forM args $ const $ newName ""

        let exp = returnE $ appsE (TH.VarE callThis) 
                      [ intE i
                      , intE $ length $ dAdtConstructors adt
                      , TH.ListE $ map varE paramNames ]
        tellOne $ valD' (bindTo name) 
                $ if null args 
                  then exp
                  else lamE' paramNames exp

      tellOne x    = tell [x]

type ToplevelName = Name
data ExpInstantiatorData = ExpInstantiatorData 
  { toplevelNames :: [ToplevelName]
  , profiling     :: Bool
  , adts          :: [Declaration]
  }

newtype ExpInstantiator u a = ExpInstantiator 
  { runExpInstantiator :: ReaderT ExpInstantiatorData u a } 
  deriving (Monad, MonadUnique, MonadReader ExpInstantiatorData)

isToplevelName :: Monad u => ToplevelName -> ExpInstantiator u Bool
isToplevelName name = asks $ elem name . toplevelNames

instance MonadUnique u => MonadTHInstantiator (ExpInstantiator u) where

  instantiateName = return . convertName . encodedName

  instantiateVar (EVar n) = isToplevelName n >>= \case
    True  -> liftM (                            TH.VarE) $ instantiateName n 
    False -> liftM (TH.AppE (TH.VarE 'return) . TH.VarE) $ instantiateName n

  instantiateCon (ECon n) = return $ varE $ encodedConsName n

  instantiateApp (EApp f args) = do
    args'    <- instantiate args
    case f of
      ECon cName -> bindAndApplyArgs (appsE $ varE $ encodedConsName cName) args'
      EVar fName -> case convertName fName of
        "==" -> instantiateEq args'
        _    -> instantiateCachedApp fName args'

    where 
      instantiateCachedApp fName args' = 
        bindAndApplyArgs (\args'' -> 
          appsE (TH.VarE 'withCache) 
          [ appsE (TH.ConE 'CacheCall) [stringE $ encodedName fName, TH.ListE args'']
          , appsE (varE $ encodedName fName) args''
          ]) args'

      instantiateEq args' = do
        scheme <- liftM toTH $ schemeOfExp $ head args
        bindAndApplyArgs (\args'' -> 
          appsE (TH.VarE 'withCache) 
          [ appsE (TH.ConE 'CacheCall) [stringE "encEq", TH.ListE args'']
          , appsE (TH.VarE 'encEq) $ typedUndefined scheme : args''
          ]) args'

  instantiateCase (ECase e ms) = do
    e'Name <- newName "bindCase"
    e'     <- instantiate e
    ms'    <- instantiateMatches e'Name ms

    let binding = bindS' e'Name e'

    if lengthOne ms'
      then return $ TH.DoE [ binding, TH.NoBindS $ head ms' ]

      else do caseOfE <- bindAndApply 
                (\ms'Names -> [ varE e'Name, TH.ListE $ map varE ms'Names ])
                (\exps -> appsE (TH.VarE 'withCache)
                            [ appsE (TH.ConE 'CacheCase) exps
                            , appsE (TH.VarE 'caseOf) exps 
                            ]
                ) ms'

              return $ TH.DoE [ binding, TH.NoBindS $ checkBottom e'Name 
                                                    $ caseOfE ]
    where 
      -- Instantiate matches
      instantiateMatches e'Name matches =
        getAdt >>= \case 
          Nothing  -> error "Algorithms.Eitherize.instantiateMatches: no ADT found"
          Just adt -> zipWithM instantiateMatch [0..] $ dAdtConstructors adt
        
        where
          -- Default match
          defaultMatch = case last matches of m@(Match (PVar _) _) -> Just m
                                              _                    -> Nothing

          -- Instantiate match of @j@-th constructor, namely @CCon c _@
          instantiateMatch j (CCon c _) = case matchFromConstructor c of
            Match (PVar v) exp -> do
              v' <- instantiateName v
              liftM (letE' [(v', varE e'Name)]) $ instantiate exp

            Match (PCon _ []) exp -> instantiate exp

            Match (PCon _ ps) exp -> do
              bindings' <- zipWithM mkBinding [0..] psNames
              exp'      <- instantiate exp
              return $ letE' bindings' exp'
              where 
                mkBinding i var = do 
                  var' <- instantiateName var 
                  return (var', eConstructorArg i)

                eConstructorArg i = appsE (TH.VarE 'constructorArgument) 
                                          [ intE i, intE j, varE e'Name ]

                psNames = map (\(PVar p) -> nUntyped p) ps
            
          -- Finds the corresponding match for constructor @c@
          matchFromConstructor c = 
            case find byMatch matches of
              Nothing -> case defaultMatch of
                            Nothing -> error $ "Algorithms.Eitherize.matchFromConstructor: no match for constructor '" ++ fromName c ++ "'"
                            Just m  -> m
              Just m  -> m

            where byMatch (Match (PVar _  ) _) = False
                  byMatch (Match (PCon p _) _) = untypedName p == c

          -- Finds the corresponding ADT for the matches
          getAdt = asks (find (any isConstructor . dAdtConstructors) . adts)
            where 
              PCon p _ = matchPattern $ head $ matches
              isConstructor (CCon c _) = untypedName p == c

      checkBottom e'Name = 
          TH.CondE (TH.AppE (TH.VarE 'isBottom) (varE e'Name))
                   (TH.AppE (TH.VarE 'return) (varE e'Name))

  instantiateLet (ELet bindings exp) = do
    exp'      <- instantiate exp 
    bindings' <- mapM bindValue bindings
    return $ TH.DoE $ bindings' ++ [ TH.NoBindS exp' ]

    where 
      bindValue (Binding name value) = do
        name'  <- instantiateName name
        value' <- instantiate value
        return $ bindS' name' value'

  instantiateBind (DBind (Binding name exp)) = do
    name'        <- instantiateName name
    exp'         <- instantiate exp
    profiledExp' <- asks profiling >>= return . \case 
      False -> exp'
      True  -> case exp' of
        TH.LamE patterns exp'' -> TH.LamE patterns 
                                $ appsE (TH.VarE 'traced) [ stringE name, exp'' ]
        _                      -> appsE (TH.VarE 'traced) [ stringE name, exp' ]
    return [ valD' name' profiledExp' ]

-- |@eitherize prof p@ eitherizes a first order program into a Template-Haskell program.
-- @prof@ enables profiling.
eitherize :: MonadUnique u => Bool -> Program -> u [TH.Dec]
eitherize profiling program = do
  typedProgram <- schemes program

  let (adts,values) = splitDeclarations typedProgram 
      toplevelNames = map boundName $ programToplevelBindings program

  decls   <- execWriterT $ runAdtInstantiator $ collect     adts
  values' <- liftM concat $ runReaderT 
                (runExpInstantiator $ instantiate $ map DBind values)
                (ExpInstantiatorData toplevelNames profiling adts)
                         
  return $ {-deleteSignatures $-} decls ++ values'


-- |@bindAndApply mapping f args@ binds @args@ to new names @ns@, maps $ns$ to 
-- expressions @es@ by @mapping@, applies @f@ to @es@ and
-- binds the result to a new name @r@. The last statement is @return r@.
bindAndApply :: MonadUnique u => ([Name] -> [TH.Exp]) -> ([TH.Exp] -> TH.Exp) 
                              -> [TH.Exp] -> u TH.Exp
bindAndApply mapping f args = do
  resultName <- newName "bindResult"
  argNames   <- forM args $ const $ newName "bindArgument"

  let bindings     = map (\(n,e) -> TH.BindS (varP n) e) $ zip argNames args
      applied      = f $ mapping argNames
      returnResult = [ TH.BindS     (varP resultName) applied
                     , TH.NoBindS $ returnE $ varE resultName
                     ]
  return $ TH.DoE $ bindings ++ returnResult

-- |@bindAndApplyArgs f args@ binds @args@ to new names @ns@,
-- applies @f@ to @ns@ and binds the result to a new name @r@. 
-- The last statement is @return r@.
bindAndApplyArgs :: MonadUnique u => ([TH.Exp] -> TH.Exp) 
                                  -> [TH.Exp] -> u TH.Exp
bindAndApplyArgs = bindAndApply (map varE) 
