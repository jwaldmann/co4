-- |Utility functions
module CO4.Util
where

import           Data.List (partition,find,maximumBy)
import           Data.Maybe (mapMaybe)
import           CO4.Language
import           CO4.Names
import           CO4.PPrint
import           CO4.TypesUtil (countTCon)

-- |Gets all declarations of a program
programDeclarations :: Program -> [Declaration]
programDeclarations (Program main decls) = (DBind main) : decls

-- |Gets all top-level bindings of a program
programToplevelBindings :: Program -> [Binding]
programToplevelBindings (Program main decls) = main : (mapMaybe fromDecl decls)

  where fromDecl (DBind b) = Just b
        fromDecl _         = Nothing

-- |Gets the name of the main binding
mainName :: Program -> Name
mainName = boundName . pMain

-- |Builds a program from a list of declarations. Fails if main binding is not found.
programFromDeclarations :: Name -> [Declaration] -> Program
programFromDeclarations mainName decls  = case partition isMain decls of
  ([DBind main],rest) -> Program main rest
  ([],_) -> error $ "Util.programFromDeclarations: no top-level '" ++ show (pprint mainName) ++ "' binding found"
  (_,_)  -> error $ "Util.programFromDeclarations: multiple top-level '" ++ show (pprint mainName) ++ "' bindings found"
  
  where isMain (DBind (Binding name _)) = name == mainName 
        isMain _                        = False

-- |Finds a top-level binding by its name
toplevelBindingByName :: Name -> Program -> Maybe Binding
toplevelBindingByName name = find (\(Binding n _) -> n == name) . programToplevelBindings

-- |Splits top-level declarations into type declarations and value declarations
splitDeclarations :: Program -> ([Declaration], [Binding])
splitDeclarations = foldl split ([],[]) . programDeclarations
  where split (types, vals) d@(DAdt {}) = (types ++ [d], vals)
        split (types, vals)   (DBind b) = (types, vals ++ [b])

-- |Adds declarations to a program
addDeclarations :: [Declaration] -> Program -> Program
addDeclarations decls program = program { pDecls = pDecls program ++ decls }

-- |Checks whether an ADT is directly recursive, i.e. if one of its constructor's 
-- arguments refers to the ADT itself. 
-- Recursions along other ADTs are not checked.
isRecursiveAdt :: Declaration -> Bool
isRecursiveAdt = not . null . fst . splitConstructors

-- |Splits the constructors of an ADT into recursive constructors and 
-- non-recursive constructors
splitConstructors :: Declaration -> ([Constructor],[Constructor])
splitConstructors (DAdt name _ conss) = partition isRecursiveCons conss
  where isRecursiveCons c = countTConInConstructor name c > 0

-- |Counts the number of recursive constructor arguments
countRecursiveConstructorArguments :: Declaration -> Int
countRecursiveConstructorArguments (DAdt name _ conss) = 
  sum $ map (countTConInConstructor name) conss

-- |Counts how often a certain type constructor is present in a constructor
countTConInConstructor :: UntypedName -> Constructor -> Int
countTConInConstructor name = sum . map (countTCon name) . cConArgumentTypes

-- |Gets all constructor's argument types
allConstructorsArgumentTypes :: Declaration -> [Type]
allConstructorsArgumentTypes = concatMap cConArgumentTypes . dAdtConstructors

-- |Replaces an element at a certain position in a list
replaceAt :: Int -> a -> [a] -> [a]
replaceAt _ _ []     = []
replaceAt 0 y (_:xs) = y : xs
replaceAt i y (x:xs) = x : ( replaceAt (i-1) y xs )

-- |Replaces the first element in a list that matches a predicate 
replaceBy :: (a -> Bool) -> a -> [a] -> [a]
replaceBy _ _ [] = []
replaceBy f y (x:xs) | f x       = y : xs
replaceBy f y (x:xs) | otherwise = x : ( replaceBy f y xs )

-- |Checks whether a list has length one
lengthOne :: [a] -> Bool
lengthOne l = case l of [_] -> True ; _ -> False

-- |Gets maximum of a list by applying a mapping to a type of class 'Ord'
maximumBy' :: Ord b => (a -> b) -> [a] -> a
maximumBy' f = maximumBy (\a b -> compare (f a) (f b))

-- * Smart constructors using 'Namelike'
-- There are also redefinitions of constructors
-- without namelike parameters, for the sake of consistent code.

tVar :: Namelike n => n -> Type
tVar = TVar . untypedName

tCon :: Namelike n => n -> [Type] -> Type
tCon n = TCon $ untypedName n

sType :: Type -> Scheme
sType = SType

sForall :: Namelike n => n -> Scheme -> Scheme
sForall n = SForall $ untypedName n

nUntyped :: Namelike n => n -> Name
nUntyped = NUntyped . fromName

nTyped :: Namelike n => n -> Scheme -> Name
nTyped n = NTyped $ fromName n

pVar :: Namelike n => n -> Pattern
pVar = PVar . name

pCon :: Namelike n => n -> [Pattern] -> Pattern
pCon n = PCon $ name n

match :: Pattern -> Expression -> Match
match = Match

binding :: Namelike n => n -> Expression -> Binding
binding n = Binding $ name n

eVar :: Namelike n => n -> Expression
eVar = EVar . name

eCon :: Namelike n => n -> Expression
eCon = ECon . name

eApp :: Expression -> [Expression] -> Expression
eApp = EApp

eApp' :: Expression -> Expression -> Expression
eApp' a b = EApp a [b]

eApp'' :: Expression -> Expression -> Expression -> Expression
eApp'' a b c = EApp a [b,c]

eTApp :: Expression -> [Type] -> Expression
eTApp = ETApp

eLam :: Namelike n => [n] -> Expression -> Expression
eLam ns = ELam (map name ns)

eTLam :: Namelike n => [n] -> Expression -> Expression
eTLam ns = ETLam (map untypedName ns)

eCase :: Expression -> [Match] -> Expression
eCase = ECase

eLet :: [Binding] -> Expression -> Expression
eLet = ELet 

cCon :: Namelike n => n -> [Type] -> Constructor
cCon n = CCon (untypedName n)

dBind :: Binding -> Declaration
dBind = DBind 

dAdt :: (Namelike n, Namelike m) => n -> [m] -> [Constructor] -> Declaration
dAdt n m = DAdt (untypedName n) (map untypedName m)

-- |Pattern-to-expression transformation
patternToExpression :: Pattern -> Expression
patternToExpression pat = case pat of
  PVar n    -> EVar n
  PCon n [] -> ECon n
  PCon n ps -> EApp (ECon n) $ map patternToExpression ps

-- |Expression-to-pattern transformation
expressionToPattern :: Expression -> Pattern 
expressionToPattern exp = case exp of
  EVar n           -> PVar n
  ECon n           -> PCon n []
  EApp (ECon n) es -> PCon n $ map expressionToPattern es

