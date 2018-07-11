-- Automatic random generator for Substance programs
-- Author: Dor Ma'ayan, July 2018

{-# LANGUAGE AllowAmbiguousTypes       #-}
{-# LANGUAGE DeriveDataTypeable        #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE RankNTypes                #-}
{-# LANGUAGE UnicodeSyntax             #-}

import System.Random
import System.IO
import System.IO.Unsafe
import System.Exit
import System.Environment
import Data.List
import Data.String
import Data.Typeable
import Control.Monad (when)
import Env
import Debug.Trace
import Text.Show.Pretty

import qualified Dsll as D
import qualified Data.Map.Strict as M

-----------------------------  Randomness Definitions --------------------------
type Interval = (Int, Int)

{-# NOINLINE seedRnd #-}
seedRnd :: Int
seedRnd = unsafePerformIO $ getStdRandom (randomR (9,99))

-- | Refresh the StdGen in a given localEnv
updateGen :: LocalEnv -> LocalEnv
updateGen env = env{gen = mkStdGen (seed env * 7), seed = seed env * 7 }

rndNum :: LocalEnv -> Interval -> (Int,LocalEnv)
rndNum env rng = let n = fst (randomR rng (gen env)) :: Int
                     env1 = updateGen env
                 in (n,env1)
-----------------------------  Generator Env -----------------------------------
-- The goal of the local env is to track the
data LocalEnv = LocalEnv {
                       availableNames :: Language,
                       declaredTypes :: M.Map String [String], -- Map from type to list of object from that type
                       pred1Lst :: [Predicate1],
                       pred2Lst :: [Predicate2],
                       prog :: String, --String representing the generated program
                       gen :: StdGen, -- A random generator which will be updated regulary
                       seed :: Int -- A random seed which is updated regulary
                     }
              deriving (Show, Typeable)

-- | Add declared type statement to the local env of the generator
addDeclaredType :: LocalEnv -> String -> String -> LocalEnv
addDeclaredType localEnv t typeName = case M.lookup t (declaredTypes localEnv) of
  Nothing -> localEnv { declaredTypes =  M.insert t [typeName] (declaredTypes localEnv) }
  Just v -> localEnv { declaredTypes = M.insert t (typeName : v) (declaredTypes localEnv) }

------------------------------ Substance Generator -----------------------------

-- | The main function of the genrator.
--   arguments: Dsll file, name file
--   parse the input Dsll file, preform type checking and get the environment
--   load the names from the names file
main :: IO ()
main = do
    args <- getArgs
    when (length args /= 2) $ die "Usage: ./Main prog.dsl namesFile"
    let (dsllFile, namesFile) = (head args,args !! 1)
    dsllIn <- readFile dsllFile
    dsllEnv <- D.parseDsllSilent dsllFile dsllIn
    generatePrograms dsllEnv namesFile 1
    return ()

-- | Generate n random programs
generatePrograms :: VarEnv -> String -> Int -> IO ()
generatePrograms dsllEnv namesFile n =
    when (n/=0) $
    do generateProgram dsllEnv namesFile
       generatePrograms dsllEnv namesFile (n-1)

-- | The top level function for automatic generation of substance programs,
--   calls other functions to generate specific statements
generateProgram :: VarEnv -> String -> IO ()
generateProgram dsllEnv namesFile = do
    let localEnv1 = generateTypes dsllEnv initLocalEnv 3
        localEnv2 = generateStatements dsllEnv localEnv1 10
    putStrLn "Program: \n"
    putStrLn (prog localEnv2)
    --putStrLn "\n And the local env is: \n"
    --pPrint localEnv2
    return ()
    where initLocalEnv = LocalEnv {declaredTypes = M.empty, availableNames = loadLanguage namesFile,
       pred1Lst = getPred1Lst dsllEnv, pred2Lst = getPred2Lst dsllEnv,
       gen = mkStdGen seedRnd, seed = seedRnd, prog = "" }

-- | Generate random Substance statements
generateStatements :: VarEnv -> LocalEnv -> Int -> LocalEnv
generateStatements dsllEnv localEnv n =
    let localEnv1 = generateStatement dsllEnv localEnv
    in if n /= 1 then generateStatements dsllEnv localEnv1 (n - 1)
                 else localEnv1

-- | Generate single random Substance statement
generateStatement :: VarEnv -> LocalEnv -> LocalEnv
generateStatement dsllEnv localEnv =
    let (statementId, localEnv1) = rndNum localEnv (0,2)
        localEnv2 = case statementId of
                 0 -> generateBinding dsllEnv localEnv1
                 1 -> localEnv1 --generatePrediacte dsllEnv localEnv1
                 2 -> localEnv1 --generatePrediacteEquality dsllEnv localEnv1
    in localEnv2 {prog = prog localEnv2 ++ "\n"}

-- | Generate random type statements
generateTypes :: VarEnv -> LocalEnv -> Int -> LocalEnv
generateTypes dsllEnv localEnv n =
    let localEnv1 = generateType dsllEnv localEnv
    in if n /= 1 then generateTypes dsllEnv localEnv1 (n - 1)
                   else localEnv1

-- | Generate single random type statement
generateType :: VarEnv -> LocalEnv -> LocalEnv
generateType dsllEnv localEnv =
    let types = M.toAscList (typeConstructors dsllEnv)
        (t, localEnv1) = rndNum localEnv (0,length types-1)
        (name, localEnv2) = getName localEnv1
        tName = fst (types !! t)
        localEnv3 = addDeclaredType localEnv2 tName name
        in localEnv3 {prog = prog localEnv3 ++ tName ++ " " ++ name ++ " \n" }

-- | Generate single random specific type statement
generateSpecificType :: VarEnv -> LocalEnv -> String -> LocalEnv
generateSpecificType dsllEnv localEnv tName =
    let (name, localEnv1) = getName localEnv
        localEnv2 = addDeclaredType localEnv1 tName name
        localEnv3 = localEnv2 {prog = prog localEnv2 ++ tName ++ " " ++ name ++ " \n" }
    in  localEnv3

-- | Generate single random binding statement
generateBinding :: VarEnv -> LocalEnv -> LocalEnv
generateBinding dsllEnv localEnv =
    let operations = M.toAscList (operators dsllEnv)
        (o, localEnv1) = rndNum localEnv (0,length operations - 1)
        operation = snd (operations !! o)
        allTypes = top operation : tlsop operation
        localEnv2 = generatePreDeclarations dsllEnv localEnv1 (getTypeNames allTypes)
        localEnv3 = generateArgument localEnv2 (convert (top operation))
        localEnv4 = localEnv3 { prog = prog localEnv3 ++ " := " ++ nameop operation}
        in generateArguments (getTypeNames (tlsop operation)) localEnv4

-- | Get a list of all the types needed for a specific statement and
--   add type declrations for them in case needed
generatePreDeclarations :: VarEnv -> LocalEnv -> [String] -> LocalEnv
generatePreDeclarations varEnv = foldl (generatePreDeclaration varEnv)

-- | Add a specific declaration in case needed
generatePreDeclaration :: VarEnv -> LocalEnv -> String -> LocalEnv
generatePreDeclaration dsllEnv localEnv t =
  case M.lookup t (declaredTypes localEnv) of
    Nothing -> generateSpecificType dsllEnv localEnv t
    Just lst -> let (i , localEnv1) = rndNum localEnv (0,length lst)
                in if i == 0 || i == 1 then generateSpecificType dsllEnv localEnv1 t else localEnv1


-- | Generate single random predicate equality
generatePrediacteEquality :: VarEnv -> LocalEnv -> LocalEnv
generatePrediacteEquality dsllEnv localEnv =
    let localEnv1 = generatePrediacte dsllEnv localEnv
        localEnv2 = localEnv1 {prog = prog localEnv1 ++ " <-> "}
        in generatePrediacte dsllEnv localEnv2

-- | Generate single random operation statement
generatePrediacte :: VarEnv -> LocalEnv -> LocalEnv
generatePrediacte dsllEnv localEnv =
    let preds = M.toAscList (predicates dsllEnv)
        (p , localEnv1) = rndNum localEnv (0,length preds - 1)
        predicate = snd (preds !! p)
    in case predicate of
            Pred1 p1 -> generatePrediacte1 dsllEnv localEnv1
            Pred2 p2 -> generatePrediacte2 dsllEnv localEnv1

generatePrediacte1 :: VarEnv -> LocalEnv -> LocalEnv
generatePrediacte1 dsllEnv localEnv =
    let (p , localEnv1) = rndNum localEnv (0,length (pred1Lst localEnv) -1)
        predicate = pred1Lst localEnv1 !! p
        localEnv2 = generatePreDeclarations dsllEnv localEnv1 (getTypeNames (tlspred1 predicate))
        localEnv3 = localEnv2 {prog = prog localEnv2 ++ namepred1 predicate}
        localEnv4 = generateArguments (getTypeNames (tlspred1 predicate)) localEnv3
    in localEnv4

generatePrediacte1' :: VarEnv -> LocalEnv -> LocalEnv
generatePrediacte1' dsllEnv localEnv =
  let (p , localEnv1) = rndNum localEnv (0,length (pred1Lst localEnv) -1)
      predicate = pred1Lst localEnv1 !! p
      localEnv2 = localEnv1 {prog = prog localEnv1 ++ namepred1 predicate ++ "("}
      localEnv3 = generateArguments (getTypeNames (tlspred1 predicate)) localEnv2
  in localEnv3

generatePrediacte2 :: VarEnv -> LocalEnv -> LocalEnv
generatePrediacte2 dsllEnv localEnv =
        let --allPreds = M.toAscList (predicates dsllEnv)
            g = mkStdGen 9
            l = length (pred2Lst localEnv) - 1
            p = fst (randomR (0, l) g)
            predicate = pred2Lst localEnv !! p
            localEnv1 = localEnv { prog = prog localEnv ++ namepred2 predicate ++ "("}
            n  = length (plspred2 predicate)
            localEnv2 = generatePred2Args dsllEnv localEnv1 n
        in  localEnv2

generatePred2Args :: VarEnv -> LocalEnv -> Int -> LocalEnv
generatePred2Args dsllEnv localEnv n =
     let localEnv1 = generatePrediacte1' dsllEnv localEnv
     in if n /= 1 then let localEnv2 = localEnv1 {prog = prog localEnv1 ++ ","}
                       in generatePred2Args dsllEnv localEnv2 (n - 1)
        else localEnv1 {prog = prog localEnv1 ++ ")"}

generatePred2Arg :: VarEnv -> LocalEnv -> LocalEnv
generatePred2Arg = generatePrediacte1 -- TODO: Add nesting
------------------------------- Helper Functions -------------------------------
getTypeNames = map convert

convert :: T ->  String
convert (TTypeVar t) = typeVarName t
convert (TConstr t) = nameCons t

generateArguments :: [String] -> LocalEnv -> LocalEnv
generateArguments types localEnv =
  let localEnv1 = localEnv {prog = prog localEnv ++ "("}
      localEnv2 = foldl generateFullArgument localEnv1 types
      localEnv3 = localEnv2 {prog = init (fromString (prog localEnv2)) ++ ")"}
  in localEnv3

-- | Get an argument for operations / predicates / val constructors
generateArgument :: LocalEnv -> String -> LocalEnv
generateArgument localEnv t = case M.lookup t (declaredTypes localEnv) of
  Nothing -> error "Generation Error!"
  Just lst -> let (a, localEnv1) = rndNum localEnv (0,length lst -1)
              in localEnv1 { prog = prog localEnv1 ++ lst !! a}

-- | Get an argument for operations / predicates / val constructors
generateFullArgument :: LocalEnv -> String -> LocalEnv
generateFullArgument localEnv t =
  case M.lookup t (declaredTypes localEnv) of
    Nothing -> error "Generation Error!"
    Just lst -> let (a, localEnv1) = rndNum localEnv (0,length lst -1)
                in localEnv1 { prog = prog localEnv1 ++ lst !! a ++ ","}


getPred1Lst :: VarEnv -> [Predicate1]
getPred1Lst dsllEnv = let preds = M.toAscList (predicates dsllEnv)
                      in concatMap extractPred1 preds

getPred2Lst :: VarEnv -> [Predicate2]
getPred2Lst dsllEnv = let preds = M.toAscList (predicates dsllEnv)
                      in concatMap extractPred2 preds

extractPred1:: (String,PredicateEnv) -> [Predicate1]
extractPred1 (_ , Pred1 p) = [p]
extractPred1 _ = []

extractPred2:: (String,PredicateEnv) -> [Predicate2]
extractPred2 (_ , Pred2 p) = [p]
extractPred2 _ = []


-----------------------------  Randomize Names ---------------------------------
-- The mechanism for randomization of names for entities in
-- the random Substance programs

-- | Language is defined as a list of strings
type Language = [String]

-- | Load the language from a file in FilePath
loadLanguage :: FilePath -> [String]
loadLanguage path = let content = readFile path
                        ls = lines (unsafePerformIO content)
                    in  ls

-- | Given localEnv, get a random name from all the available names and return
--   it as well as the localEnv excluding that name
getName :: LocalEnv -> (String, LocalEnv)
getName localEnv = let names = availableNames localEnv
                       (i, localEnv1) = rndNum localEnv (0,length names -1)
                       name = names !! i
                   in (name, localEnv1 {availableNames = delete name (availableNames localEnv1)})
