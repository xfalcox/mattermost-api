{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DeriveDataTypeable #-}

module Network.Mattermost.WebSocket
( MMWebSocket
, MMWebSocketTimeoutException
, mmWithWebSocket
, mmCloseWebSocket
, mmSendWSAction
, mmGetConnectionHealth
, module Network.Mattermost.WebSocket.Types
) where

import           Control.Concurrent (ThreadId, forkIO, myThreadId, threadDelay)
import qualified Control.Concurrent.STM.TQueue as Queue
import           Control.Exception (Exception, SomeException, catch, throwIO, throwTo, try)
import           Control.Monad (forever)
import           Control.Monad.STM (atomically)
import           Data.Aeson (toJSON)
import qualified Data.ByteString.Char8 as B
import           Data.ByteString.Lazy (toStrict)
import           Data.IORef
import           Data.Monoid ((<>))
import qualified Data.Text as T
import           Data.Time.Clock (NominalDiffTime, UTCTime, diffUTCTime, getCurrentTime)
import           Data.Typeable ( Typeable )
import           Network.Connection ( Connection
                                    , connectionClose
                                    , connectionGet
                                    , connectionPut
                                    )
import qualified Network.WebSockets as WS
import           Network.WebSockets.Stream (Stream, makeStream)

import           Network.Mattermost.Util
import           Network.Mattermost.Types.Base
import           Network.Mattermost.Types.Internal
import           Network.Mattermost.Types
import           Network.Mattermost.WebSocket.Types


connectionToStream :: Connection -> IO Stream
connectionToStream con = makeStream rd wr
  where wr Nothing   = connectionClose con
        wr (Just bs) = connectionPut con (toStrict bs)
        rd = do
          bs <- connectionGet con 1024
          return $ if B.null bs
            then Nothing
            else Just bs

data MMWebSocket = MMWS WS.Connection (IORef NominalDiffTime)

data MMWebSocketTimeoutException = MMWebSocketTimeoutException
  deriving (Show, Typeable)

instance Exception MMWebSocketTimeoutException where

data PEvent = P UTCTime

createPingPongTimeouts :: ThreadId
                       -> IORef NominalDiffTime
                       -> Int
                       -> (LogEventType -> IO ())
                       -> IO (IO (), IO (), ThreadId)
createPingPongTimeouts pId health n doLog = do
  pingChan <- Queue.newTQueueIO
  pongChan <- Queue.newTQueueIO
  let pingAction = do
        now <- getCurrentTime
        doLog WebSocketPing
        atomically $ Queue.writeTQueue pingChan (P now)
  let pongAction = do
        now <- getCurrentTime
        doLog WebSocketPong
        atomically $ Queue.writeTQueue pongChan (P now)
  watchdogPId <- forkIO $ do
      let go = do
            P old <- atomically $ Queue.readTQueue pingChan
            threadDelay (n * 1000 * 1000)
            b <- atomically $ Queue.isEmptyTQueue pongChan
            if b
              then throwTo pId MMWebSocketTimeoutException
              else do
                P new <- atomically $ Queue.readTQueue pongChan
                atomicWriteIORef health (new `diffUTCTime` old)
                go
      go

  return (pingAction, pongAction, watchdogPId)

mmCloseWebSocket :: MMWebSocket -> IO ()
mmCloseWebSocket (MMWS c _) = WS.sendClose c B.empty

mmGetConnectionHealth :: MMWebSocket -> IO NominalDiffTime
mmGetConnectionHealth (MMWS _ h) = readIORef h

pingThread :: IO () -> WS.Connection -> IO ()
pingThread onPingAction conn = loop 0
  where loop :: Int -> IO ()
        loop n = do
          threadDelay (10 * 1000 * 1000)
          onPingAction
          WS.sendPing conn (B.pack (show n))
          loop (n+1)

mmWithWebSocket :: Session
                -> (Either String WebsocketEvent -> IO ())
                -> (MMWebSocket -> IO ())
                -> IO ()
mmWithWebSocket (Session cd (Token tk)) recv body = do
  con <- mkConnection (cdConnectionCtx cd) (cdHostname cd) (cdPort cd) (cdUseTLS cd)
  stream <- connectionToStream con
  health <- newIORef 0
  myId <- myThreadId
  let doLog = runLogger cd "websocket"
  (onPing, onPong, _) <- createPingPongTimeouts myId health 8 doLog
  let action c = do
        pId <- forkIO (pingThread onPing c `catch` cleanup)
        mId <- forkIO $ flip catch cleanup $ forever $ do
          result <- try $ do
              v <- WS.receiveData c
              v `seq` return v
          val <- case result of
                Left (WS.ParseException e) -> return $ Left e
                Left e -> throwIO e
                Right ws -> return $ Right ws
          doLog (WebSocketResponse $ case val of
                Left s -> Left s
                Right v -> Right $ toJSON v)
          recv val
        body (MMWS c health) `catch` propagate [mId, pId]
  WS.runClientWithStream stream
                      (T.unpack $ cdHostname cd)
                      "/api/v4/websocket"
                      WS.defaultConnectionOptions { WS.connectionOnPong = onPong }
                      [ ("Authorization", "Bearer " <> B.pack tk) ]
                      action
  where cleanup :: SomeException -> IO ()
        cleanup _ = return ()
        propagate :: [ThreadId] -> SomeException -> IO ()
        propagate ts e = do
          sequence_ [ throwTo t e | t <- ts ]
          throwIO e

mmSendWSAction :: ConnectionData -> MMWebSocket -> WebsocketAction -> IO ()
mmSendWSAction cd (MMWS ws _) a = do
  runLogger cd "websocket" $ WebSocketRequest $ toJSON a
  WS.sendTextData ws a
