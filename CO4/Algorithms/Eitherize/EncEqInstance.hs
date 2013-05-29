{-# LANGUAGE TemplateHaskell #-}
module CO4.Algorithms.Eitherize.EncEqInstance
  (encEqInstance)
where

import           Prelude hiding (and)
import           Control.Monad (forM,zipWithM,liftM)
import qualified Language.Haskell.TH as TH
import           CO4.Unique (MonadUnique,newName)
import           CO4.Language
import           CO4.Names (Namelike)
import           CO4.EncEq (EncEq (..))
import           CO4.EncodedAdt 
import           CO4.Algorithms.Eitherize.Names (encodedName)
import           CO4.Algorithms.THInstantiator (toTH)
import           CO4.THUtil
import           CO4.TypesUtil (typeOfAdt)
import           CO4.Util (replaceAt,for)

-- |Generates a @EncEq@ instance
--
-- > instance (EncEq v1,...) => EncEq (T v1 ...) where
-- >   encEq _ x y = 
-- >     eq00  <- encEq (undefined :: T00) (constructorArgument 0 0 x) 
-- >                                       (constructorArgument 0 0 y)
-- >     eq10  <- encEq (undefined :: T10) (constructorArgument 1 0 x) 
-- >                                       (constructorArgument 1 0 y)
-- >     ...
-- >     eq0   <- and [eq00, eq10, eq20, ...]
-- >     eq1   <- and [eq01, eq11, eq21, ...]
-- >     ...
-- >   
-- >     eqY0  <- caseOf y [eq0, encFalseCons, encFalseCons, ...]
-- >     eqY1  <- caseOf y [encFalseCons, eq1, encFalseCons, ...]
-- >     ...
-- >     caseOf x [y0, y1, ...]
encEqInstance :: MonadUnique u => Declaration -> u TH.Dec
encEqInstance adt@(DAdt name vars conss) = 
  let predicates = for vars $ \p -> TH.ClassP ''EncEq [varT p]
      
      instanceHead = TH.InstanceD predicates $ TH.AppT (TH.ConT ''EncEq)
                                             $ appsT (conT name)
                                             $ map varT vars
  in do
    [x,y] <- mapM newName ["x","y"]
    body  <- encEqBody x y conss 

    let thType           = toTH $ typeOfAdt adt
        mkClause b       = TH.Clause [typedWildcard thType, varP x, varP y] b []
        mkBottomClause n = mkClause $ TH.GuardedB [
          ( TH.NormalG $ TH.AppE (TH.VarE 'isBottom) (varE n)
          , TH.AppE (TH.VarE 'return) (TH.VarE 'bottom) )]

        clauses = 
          [ mkBottomClause x
          , mkBottomClause y
          , mkClause $ TH.NormalB body
          ]

    return $ instanceHead [funD "encEq" clauses]

encEqBody :: (MonadUnique u,Namelike n) => n -> n -> [Constructor] -> u TH.Exp
encEqBody x y conss = do
  (eqJNames, eqIJStmts) <- liftM unzip $ zipWithM eqConstructor [0..] conss

  eqYNames  <- forM conss $ const $ newName "eqY"

  let encFalse    = appsE (TH.VarE 'encodedConstructor) [intE 0, intE 2, TH.ListE []]
      eqYStmt j n = bindS' n $ appsE (TH.VarE 'caseOf) 
                             $ [varE y, TH.ListE args]

        where args = replaceAt j (eqJNames !! j) 
                   $ replicate (length conss) encFalse

      eqYStmts    = zipWith eqYStmt [0..] eqYNames

      result      = appsE (TH.VarE 'caseOf) [varE x, TH.ListE $ map varE eqYNames]

  return $ TH.DoE $ concat eqIJStmts ++ eqYStmts ++ [TH.NoBindS result]

  where 
    
    eqConstructor _ (CCon _ []) = return (encTrue, [])
      where 
        encTrue = appsE (TH.VarE 'encodedConstructor) [intE 1, intE 2, TH.ListE []]

    eqConstructor j (CCon _ args) = do
      eqIJNames <- forM args $ const $ newName "eq"
      eqJName   <- newName "eq"

      let encIJs = zipWith3 (\n i -> eqIJ n i j) eqIJNames [0..] args 


          encNil      = appsE (TH.VarE 'encodedConstructor) [ intE 0, intE 2, TH.ListE []]
          encCons a b = appsE (TH.VarE 'encodedConstructor) [ intE 1, intE 2
                                                            , TH.ListE [a,b]]
          eqJ    = bindS' eqJName $ TH.AppE (varE $ encodedName "and") 
                                  $ foldr encCons encNil
                                  $ map varE eqIJNames

      return (varE eqJName, encIJs ++ [eqJ])

    eqIJ name i j t = 
      bindS' name $ appsE (TH.VarE 'encEq) 
          [ typedUndefined $ toTH t
          , appsE (TH.VarE 'constructorArgument) [intE i, intE j, varE x]
          , appsE (TH.VarE 'constructorArgument) [intE i, intE j, varE y]
          ]
