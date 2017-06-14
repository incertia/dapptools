module EVM.UnitTest where

import EVM
import EVM.ABI
import EVM.Debug
import EVM.Exec
import EVM.Keccak
import EVM.Solidity
import EVM.Types

import Control.Lens
import Control.Monad
import Control.Monad.State.Strict hiding (state)

import Data.Binary.Get    (runGetOrFail)
import Data.Text          (Text, unpack, isPrefixOf)
import Data.Text.Encoding (encodeUtf8)
import Data.Map           (Map)
import Data.Word          (Word32)
import Data.List          (sort)
import IPPrint.Colored    (cpprint)
import System.IO          (hFlush, stdout)

import qualified Data.Map as Map
import qualified Data.ByteString.Lazy as LazyByteString

tick :: String -> IO ()
tick x = putStr x >> hFlush stdout

runUnitTestContract ::
  Mode -> Map Text SolcContract -> SourceCache -> (Text, [Text]) -> IO ()
runUnitTestContract mode contractMap cache (contractName, testNames) = do
  putStrLn $ "Running " ++ show (length testNames) ++ " tests for "
    ++ unpack contractName
  case preview (ix contractName) contractMap of
    Nothing ->
      error $ "Contract " ++ unpack contractName ++ " not found"
    Just theContract -> do
      let
        vm0 = initialUnitTestVm theContract (Map.elems contractMap)
        vm2 = case runState exec vm0 of
                (VMRunning, _) ->
                  error "Internal error"
                (VMFailure e, _) ->
                  error ("Creation error: " ++ show e)
                (VMSuccess targetCode, vm1) -> do
                  execState (performCreation targetCode) vm1
        target = view (state . contract) vm2

      forM_ testNames $ \testName -> do
        let
          endowment = 0xffffffffffffffffffffffff
          vm3 = vm2 & env . contracts . ix target . balance +~ endowment
          vm4 = flip execState vm3 $ do
                  setupCall target "setUp()"
                  exec

        case view result vm4 of
          VMFailure e -> do
            tick "F"
            -- putStrLn ("failure in setUp(): " ++ show e)
            _ <- debugger (Just cache) (vm4 & state . pc -~ 1)
            return ()
          VMSuccess _ -> do
            let vm5 = execState (setupCall target testName >> exec) vm4
            case vm5 ^. result of
              VMFailure e ->
                if "testFail" `isPrefixOf` testName
                  then tick "."
                  else do
                    tick "F"
                    -- putStrLn ("unexpected failure: " ++ show e)
                    _ <- debugger (Just cache) vm5
                    return ()
              VMSuccess _ -> do
                case evalState (setupCall target "failed()" >> exec) vm5 of
                  VMSuccess out ->
                    case runGetOrFail (getAbi AbiBoolType)
                           (LazyByteString.fromStrict out) of
                      Right (_, _, AbiBool False) ->
                        tick "."
                      Right (_, _, AbiBool True) ->
                        tick "F"
                      Right (_, _, _) ->
                        error "internal error"
                      Left (_, _, e) ->
                        error ("ds-test behaving strangely: " ++ e)
                  VMFailure e ->
                    error $ "ds-test behaving strangely (" ++ show e ++ ")"
                  _ ->
                    error "internal error"
              VMRunning ->
                error "internal error"

      tick "\n"

setupCall :: Addr -> Text -> EVM ()
setupCall target abi = do
  resetState
  loadContract target
  assign (state . calldata) (word32Bytes (abiKeccak (encodeUtf8 abi)))

initialUnitTestVm :: SolcContract -> [SolcContract] -> VM
initialUnitTestVm c theContracts =
  let
    vm = makeVm $ VMOpts
           { vmoptCode = view creationCode c
           , vmoptCalldata = ""
           , vmoptValue = 0
           , vmoptAddress = newContractAddress ethrunAddress 1
           , vmoptCaller = ethrunAddress
           , vmoptOrigin = ethrunAddress
           , vmoptCoinbase = 0
           , vmoptNumber = 0
           , vmoptTimestamp = 0
           , vmoptGaslimit = 0
           , vmoptDifficulty = 0
           }
    creator =
      initialContract mempty
        & set nonce 1
        & set balance 1000000000000000000000000000
  in vm
    & set (env . contracts . at ethrunAddress) (Just creator)
    & set (env . solcByCreationHash) (Map.fromList [(view creationCodehash c, c) | c <- theContracts])
    & set (env . solcByRuntimeHash) (Map.fromList [(view runtimeCodehash c, c) | c <- theContracts])

unitTestMarkerAbi :: Word32
unitTestMarkerAbi = abiKeccak (encodeUtf8 "IS_TEST()")

findUnitTests :: [SolcContract] -> [(Text, [Text])]
findUnitTests = concatMap f where
  f c =
    case c ^? abiMap . ix unitTestMarkerAbi of
      Nothing -> []
      Just _  ->
        let testNames = unitTestMethods c
        in if null testNames
           then []
           else [(view contractName c, testNames)]

unitTestMethods :: SolcContract -> [Text]
unitTestMethods c = sort (filter (isUnitTestName) (Map.elems (c ^. abiMap)))
  where
    isUnitTestName s =
      "test" `isPrefixOf` s
