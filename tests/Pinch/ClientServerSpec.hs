{-# LANGUAGE DataKinds           #-}
{-# LANGUAGE DeriveGeneric       #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RankNTypes          #-}
{-# LANGUAGE ScopedTypeVariables #-}
module Pinch.ClientServerSpec (spec) where

import           Control.Concurrent       (forkFinally, threadDelay)
import           Control.Concurrent.Async (withAsync)
import           Control.Exception        (bracket, bracketOnError, finally)
import           Control.Monad            (forever, void)
import           Data.ByteString          (ByteString)
import           Data.Int
import           Data.IORef               (IORef, modifyIORef, newIORef,
                                           readIORef, writeIORef)
import           Data.Text                (Text)
import           GHC.Generics             (Generic)
import           Network.Run.TCP          (runTCPClient)
import           Network.Socket
import           Test.Hspec
import           Test.Hspec.QuickCheck
import           Test.QuickCheck

import qualified Data.ByteString          as BS
import qualified Data.Serialize.Get       as G

import           Pinch
import           Pinch.Arbitrary          (SomeByteString (..))
import           Pinch.Client
import           Pinch.Internal.Message
import           Pinch.Internal.RPC
import           Pinch.Protocol
import           Pinch.Server
import           Pinch.Transport

echoServer :: ThriftServer
echoServer = createServer $ \_ _ (r :: Value TStruct) ->
  pure r

data CalcRequest = CalcRequest
  { inp1 :: Field 1 Int32
  , inp2 :: Field 2 Int32
  , op   :: Field 3 Op
  } deriving (Generic, Show)
instance Pinchable CalcRequest

data Op = Plus (Enumeration 1) | Minus (Enumeration 2) | Div (Enumeration 3)
  deriving (Generic, Show)
instance Pinchable Op

data CalcResult = CalcResult
  { result :: Field 1 (Maybe Int32)
  , error  :: Field 2 (Maybe Text)
  } deriving (Generic, Show, Eq)
instance Pinchable CalcResult

calcServer :: ThriftServer
calcServer = createServer $ \_ _ r@(CalcRequest (Field inp1) (Field inp2) (Field op)) -> do
  let ret = case op of
        Plus _ -> CalcResult (Field $ Just $ inp1 + inp2) (Field Nothing)
        Minus _ -> CalcResult (Field $ Just $ inp1 - inp2) (Field Nothing)
        Div _ | inp2 == 0 -> CalcResult (Field Nothing) (Field $ Just "div by zero")
        Div _ -> CalcResult (Field $ Just $ inp1 `div` inp2) (Field Nothing)
  pure ret


spec :: Spec
spec = do
  describe "Client/Server" $ do
    prop "echo test" $ withMaxSuccess 10 $ \request -> ioProperty $
      withLoopbackServer echoServer $ \client -> do
        reply <- call client $ TCall "" request
        pure $
          reply === request

    it "calculator" $ do
      withLoopbackServer calcServer $ \client -> do
        r1 <- call client $ mkCall 10 20 Plus
        r1 `shouldBe` CalcResult (Field $ Just 30) (Field Nothing)

        r2 <- call client $ mkCall 10 20 Minus
        r2 `shouldBe` CalcResult (Field $ Just $ -10) (Field Nothing)

        r3 <- call client $ mkCall 20 10 Div
        r3 `shouldBe` CalcResult (Field $ Just 2) (Field Nothing)

        r4 <- call client $ mkCall 10 0 Div
        r4 `shouldBe` CalcResult (Field Nothing) (Field $ Just "div by zero")
  where
    mkCall inp1 inp2 op = TCall "calc" $ pinch $ CalcRequest (Field inp1) (Field inp2) (Field $ op $ Enumeration)


withLoopbackServer :: ThriftServer -> (Client -> IO a) -> IO a
withLoopbackServer srv cont = do
    addr <- resolve Stream (Just "127.0.0.1") "54093" True
    bracketOnError (open addr) close (\sock ->
      withAsync (loop sock `finally` close sock) $ \_ ->
        runTCPClient "127.0.0.1" "54093" $ \s -> do
          client <- simpleClient <$> createChannel s framedTransport binaryProtocol
          cont client
      )
  where
    open addr = bracketOnError (openServerSocket addr) close $ \sock -> do
        listen sock 1024
        return sock
    loop sock = forever $ bracketOnError (accept sock) (close . fst) $
        \(conn, _peer) ->
          void $ forkFinally (runServer conn) (const $ gracefulClose conn 5000)
    runServer sock = do
      createChannel sock framedTransport binaryProtocol
        >>= runConnection mempty srv

    resolve :: SocketType -> Maybe HostName -> ServiceName -> Bool -> IO AddrInfo
    resolve socketType mhost port passive =
        head <$> getAddrInfo (Just hints) mhost (Just port)
      where
        hints = defaultHints
          { addrSocketType = socketType
          , addrFlags = if passive then [AI_PASSIVE] else []
          }
    openServerSocket :: AddrInfo -> IO Socket
    openServerSocket addr = bracketOnError (openSocket addr) close $ \sock -> do
      setSocketOption sock ReuseAddr 1
      withFdSocket sock $ setCloseOnExecIfNeeded
      bind sock $ addrAddress addr
      return sock
