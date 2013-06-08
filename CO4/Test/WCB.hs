{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE ScopedTypeVariables #-}

module CO4.Test.WCB
where

import           Language.Haskell.TH (runIO)
import qualified Satchmo.Core.SAT.Minisat
import qualified Satchmo.Core.Decode 
import           CO4
import           CO4.Prelude
import           CO4.Util (toBinary,fromBinary)

$( runIO $ configurable [ImportPrelude] $ compileFile "CO4/Test/WCB.standalone.hs" )


uBase = constructors [ Just [], Just [], Just [], Just []]

kList 0 a = known 0 2 []
kList i a = known 1 2 [ a , kList (i-1) a]

sec = [Open,Open,Blank,Close,Open,Close ,Close,Blank ]


-- allocator = kList size uBase

result = -- solveAndTestBooleanP (Finite (toBinary Nothing size)) allocator encMain main 
    solveAndTestBooleanP sec (kList (length sec) uBase) encMain main