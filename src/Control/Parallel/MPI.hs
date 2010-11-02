{-# LANGUAGE ScopedTypeVariables #-}

-----------------------------------------------------------------------------
-- |
-- Module      : Control.Parallel.MPI
-- Copyright   : (c) 2010 Bernie Pope, Dmitry Astapov
-- License     : BSD-style
-- Maintainer  : florbitous@gmail.com
-- Stability   : experimental
-- Portability : ghc
--
-- This module provides common MPI functionality that is independent of
-- the type of message
-- being transferred between processes. Many functions in this module bear
-- a close correspondence with those provided by the C API. Such
-- correspondences are noted in the documentation of this module where
-- relevant.
-----------------------------------------------------------------------------

module Control.Parallel.MPI
   (
   -- * Notable changes from MPI
   --
   -- ** Collective operations are split
   -- $collectives-split

   -- ** Reversed order of arguments
   -- $arg-order

   -- ** Rank checking in collective functions
   -- $rank-checking

   -- ** Error handling
   -- $err-handling

   -- * Example
   -- $example

   -- * Initialization, finalization, termination.
     init
   , finalize
   , initialized
   , finalized
   , mpi
   , mpiWorld
   , initThread
   , abort

   -- * Requests and statuses.
   , Request
   , Status (..)
   , StatusPtr
   , probe
   , test
   , cancel
   , wait

   -- * Communicators and error handlers.
   , Comm
   , commWorld
   , commSelf
   , commSize
   , commRank
   , commTestInter
   , commRemoteSize
   , commCompare
   , commSetErrhandler
   , commGetErrhandler
   , commGroup
   , Errhandler
   , errorsAreFatal
   , errorsReturn
   , errorsThrowExceptions

   -- * Tags.
   , Tag
   , toTag
   , fromTag
   , tagVal
   , anyTag
   , unitTag

   -- Ranks.
   , Rank
   , rankId
   , toRank
   , fromRank
   , anySource
   , theRoot
   , procNull

   -- * Synchronization.
   , barrier

   -- * Futures.
   , Future(..)   -- XXX should this be exported abstractly? Internals needed in Serializable.
   , waitFuture
   , getFutureStatus
   , pollFuture
   , cancelFuture

   -- * Groups.
   , Group
   , groupEmpty
   , groupRank
   , groupSize
   , groupUnion
   , groupIntersection
   , groupDifference
   , groupCompare
   , groupExcl
   , groupIncl
   , groupTranslateRanks

   -- * Data types.
   , Datatype
   , char
   , wchar
   , short
   , int
   , long
   , longLong
   , unsignedChar
   , unsignedShort
   , unsigned
   , unsignedLong
   , unsignedLongLong
   , float
   , double
   , longDouble
   , byte
   , packed
   , typeSize

   -- * Operators.
   , Operation
   , maxOp
   , minOp
   , sumOp
   , prodOp
   , landOp
   , bandOp
   , lorOp
   , borOp
   , lxorOp
   , bxorOp

   -- * Comparisons.
   , ComparisonResult (..)

   -- * Threads.
   , ThreadSupport (..)
   , queryThread
   , isThreadMain

   -- * Timing.
   , wtime
   , wtick

   -- * Environment.
   , getProcessorName
   , Version (..)
   , getVersion

   ) where

import Prelude hiding (init)
import C2HS
import Control.Applicative ((<$>))
import Control.Exception (finally)
import Control.Concurrent.MVar (MVar, tryTakeMVar, readMVar)
import Control.Concurrent (ThreadId, killThread)
import qualified Control.Parallel.MPI.Internal as Internal
import Control.Parallel.MPI.Internal hiding 
   (commRank, finalize, commSize, init, initialized, finalized, initThread,
    abort, probe, test, cancel, wait, commTestInter, commRemoteSize,
    commCompare, commSetErrhandler, commGetErrhandler, commGroup, barrier,
    groupRank, groupSize, groupUnion, groupIntersection, groupDifference,
    groupCompare, groupExcl, groupIncl, groupTranslateRanks, typeSize,
    queryThread, isThreadMain, wtime, wtick, getProcessorName, getVersion)
import Control.Parallel.MPI.Utils (asBool, asInt, asEnum, enumToCInt, enumFromCInt)
import Control.Parallel.MPI.Exception as Exception

-- | A tag with unit value. Intended to be used as a convenient default.
unitTag :: Tag
unitTag = toTag ()

-- | A convenience wrapper which takes an MPI computation as its argument and wraps it
-- inside calls to 'init' (before the computation) and 'finalize' (after the computation).
-- It will make sure that 'finalize' is called even if the MPI computation raises
-- an exception (assuming the error handler is set to 'errorsThrowExceptions').
mpi :: IO () -> IO ()
mpi action = init >> (action `finally` finalize)

-- | A convenience wrapper with a similar behaviour to 'mpi'.
-- The difference is that the MPI computation is a function which is abstracted over
-- the communicator size and the process rank, both with respect to 'commWorld'.
--
-- @
-- main = mpiWorld $ \\size rank -> do
--    ...
--    ...
-- @
mpiWorld :: (Int -> Rank -> IO ()) -> IO ()
mpiWorld action = do
   init
   size <- commSize commWorld
   rank <- commRank commWorld
   action size rank `finally` finalize

-- | Initialize the MPI environment. The MPI environment must be intialized by each
-- MPI process before any other MPI function is called. Note that
-- the environment may also be initialized by the functions 'initThread', 'mpi',
-- and 'mpiWorld'. It is an error to attempt to initialize the environment more
-- than once for a given MPI program execution. The only MPI functions that may
-- be called before the MPI environment is initialized are 'getVersion',
-- 'initialized' and 'finalized'. This function corresponds to @MPI_Init@.
init :: IO ()
init = checkError Internal.init

-- | Determine if the MPI environment has been initialized. Returns @True@ if the
-- environment has been initialized and @False@ otherwise. This function
-- may be called before the MPI environment has been initialized and after it
-- has been finalized.
-- This function corresponds to @MPI_Initialized@.
initialized :: IO Bool
initialized =
   alloca $ \flagPtr -> do
      checkError $ Internal.initialized flagPtr
      peekBool flagPtr

-- | Determine if the MPI environment has been finalized. Returns @True@ if the
-- environment has been finalized and @False@ otherwise. This function
-- may be called before the MPI environment has been initialized and after it
-- has been finalized.
-- This function corresponds to @MPI_Finalized@.
finalized :: IO Bool
finalized =
   alloca $ \flagPtr -> do
      checkError $ Internal.finalized flagPtr
      peekBool flagPtr

-- | Terminate the MPI execution environment.
-- Once 'finalize' is called no other MPI functions may be called except
-- 'getVersion', 'initialized' and 'finalized'. Each process must complete
-- any pending communication that it initiated before calling 'finalize'.
-- If 'finalize' returns then regular (non-MPI) computations may continue,
-- but no further MPI computation is possible. Note: the error code returned
-- by 'finalize' is not checked. This function corresponds to @MPI_Finalize@.
finalize :: IO ()
-- XXX can't call checkError on finalize, because
-- checkError calls Internal.errorClass and Internal.errorString.
-- These cannot be called after finalize (at least on OpenMPI).
finalize = Internal.finalize >> return ()

-- | Initialize the MPI environment with a /required/ level of thread support.
-- See the documentation for 'init' for more information about MPI initialization.
-- The /provided/ level of thread support is returned in the result.
-- There is no guarantee that provided will be greater than or equal to required.
-- The level of provided thread support depends on the underlying MPI implementation,
-- and may also depend on information provided when the program is executed
-- (for example, by supplying appropriate arguments to @mpiexec@).
-- If the required level of support cannot be provided then it will try to
-- return the least supported level greater than what was required.
-- If that cannot be satisfied then it will return the highest supported level
-- provided by the MPI implementation. See the documentation for 'ThreadSupport'
-- for information about what levels are available and their relative ordering.
-- This function corresponds to @MPI_Init_thread@.
initThread :: ThreadSupport -> IO ThreadSupport
initThread required = asEnum $ checkError . Internal.initThread (enumToCInt required)

queryThread :: IO Bool
queryThread = asBool $ checkError . Internal.queryThread

isThreadMain :: IO Bool
isThreadMain = asBool $ checkError . Internal.isThreadMain

getProcessorName :: IO String
getProcessorName = do
  allocaBytes (fromIntegral Internal.maxProcessorName) $ \ptr ->
    alloca $ \lenPtr -> do
       checkError $ Internal.getProcessorName ptr lenPtr
       (len :: CInt) <- peek lenPtr
       peekCStringLen (ptr, cIntConv len)

data Version =
   Version { version :: Int, subversion :: Int }
   deriving (Eq, Ord)

instance Show Version where
   show v = show (version v) ++ "." ++ show (subversion v)

getVersion :: IO Version
getVersion = do
   alloca $ \versionPtr ->
      alloca $ \subversionPtr -> do
         checkError $ Internal.getVersion versionPtr subversionPtr
         version <- peekIntConv versionPtr
         subversion <- peekIntConv subversionPtr
         return $ Version version subversion

-- | Return the number of processes involved in a communicator. For 'commWorld'
-- it returns the total number of processes available. If the communicator is
-- and intra-communicator it returns the number of processes in the local group.
-- This function corresponds to @MPI_Comm_size@.
commSize :: Comm -> IO Int
commSize comm = asInt $ checkError . Internal.commSize comm

-- | Return the rank of the calling process for the given communicator.
-- This function corresponds to @MPI_Comm_rank@.
commRank :: Comm -> IO Rank
commRank comm =
   alloca $ \ptr -> do
      checkError $ Internal.commRank comm ptr
      toRank <$> peek ptr

commTestInter :: Comm -> IO Bool
commTestInter comm = asBool $ checkError . Internal.commTestInter comm

commRemoteSize :: Comm -> IO Int
commRemoteSize comm = asInt $ checkError . Internal.commRemoteSize comm

commCompare :: Comm -> Comm -> IO ComparisonResult
commCompare comm1 comm2 = asEnum $ checkError . Internal.commCompare comm1 comm2

-- | Test for an incomming message, without actually receiving it.
-- If a message has been sent from @Rank@ to the current process with @Tag@ on the
-- communicator @Comm@ then 'probe' will return the 'Status' of the message. Otherwise
-- it will block the current process until such a matching message is sent.
-- This allows the current process to check for an incoming message and decide
-- how to receive it, based on the information in the 'Status'.
-- This function corresponds to @MPI_Probe@.
probe :: Rank       -- ^ Rank of the sender.
      -> Tag        -- ^ Tag of the sent message.
      -> Comm       -- ^ Communicator.
      -> IO Status  -- ^ Information about the incoming message (but not the content of the message).
probe rank tag comm = do
   let cSource = fromRank rank
       cTag    = fromTag tag
   alloca $ \statusPtr -> do
      checkError $ Internal.probe cSource cTag comm $ castPtr statusPtr
      peek statusPtr

-- | Blocks until all processes on the communicator call this function.
-- This function corresponds to @MPI_Barrier@.
barrier :: Comm -> IO ()
barrier comm = checkError $ Internal.barrier comm

-- | Blocking test for the completion of a send of receive.
-- See 'test' for a non-blocking variant.
-- This function corresponds to @MPI_Wait@.
wait :: Request -> IO Status
wait request =
   alloca $ \statusPtr ->
     alloca $ \reqPtr -> do
       poke reqPtr request
       checkError $ Internal.wait reqPtr $ castPtr statusPtr
       peek statusPtr

-- | Non-blocking test for the completion of a send or receive.
-- Returns @Nothing@ if the request is not complete, otherwise
-- it returns @Just status@. See 'wait' for a blocking variant.
-- This function corresponds to @MPI_Test@.
test :: Request -> IO (Maybe Status)
test request =
    alloca $ \statusPtr ->
       alloca $ \reqPtr ->
          alloca $ \flagPtr -> do
              poke reqPtr request
              checkError $ Internal.test reqPtr (castPtr flagPtr) (castPtr statusPtr)
              flag <- peek flagPtr
              if flag
                 then Just <$> peek statusPtr
                 else return Nothing

-- | Cancel a pending communication request.
-- This function corresponds to @MPI_Cancel@.
cancel :: Request -> IO ()
cancel request =
   alloca $ \reqPtr -> do
       poke reqPtr request
       checkError $ Internal.cancel reqPtr

wtime, wtick :: IO Double
wtime = realToFrac <$> Internal.wtime

wtick = realToFrac <$> Internal.wtick

-- | A value to be computed by some thread in the future.
data Future a =
   Future
   { futureThread :: ThreadId
   , futureStatus :: MVar Status
   , futureVal :: MVar a
   }

-- | Obtain the computed value from a 'Future'. If the computation
-- has not completed, the caller will block, until the value is ready.
-- See 'pollFuture' for a non-blocking variant.
waitFuture :: Future a -> IO a
waitFuture = readMVar . futureVal

-- | Obtain the 'Status' from a 'Future'. If the computation
-- has not completed, the caller will block, until the value is ready.
getFutureStatus :: Future a -> IO Status
getFutureStatus = readMVar . futureStatus
-- XXX do we need a pollStatus?

-- | Poll for the computed value from a 'Future'. If the computation
-- has not completed, the function will return @None@, otherwise it
-- will return @Just value@.
pollFuture :: Future a -> IO (Maybe a)
pollFuture = tryTakeMVar . futureVal

-- | Terminate the computation associated with a 'Future'.
cancelFuture :: Future a -> IO ()
cancelFuture = killThread . futureThread
-- XXX May want to stop people from waiting on Futures which are killed...

-- | Return the process group from a communicator.
commGroup :: Comm -> IO Group
commGroup comm =
   alloca $ \ptr -> do
      checkError $ Internal.commGroup comm ptr
      MkGroup <$> peek ptr

groupRank :: Group -> Rank
groupRank = withGroup Internal.groupRank toRank

groupSize :: Group -> Int
groupSize = withGroup Internal.groupSize cIntConv

withGroup :: Storable a => (Group -> Ptr a -> IO CInt) -> (a -> b) -> Group -> b
withGroup prim build group =
   unsafePerformIO $
      alloca $ \ptr -> do
         checkError $ prim group ptr
         build <$> peek ptr

groupUnion :: Group -> Group -> Group
groupUnion g1 g2 = with2Groups Internal.groupUnion MkGroup g1 g2

groupIntersection :: Group -> Group -> Group
groupIntersection g1 g2 = with2Groups Internal.groupIntersection MkGroup g1 g2

groupDifference :: Group -> Group -> Group
groupDifference g1 g2 = with2Groups Internal.groupDifference MkGroup g1 g2

groupCompare :: Group -> Group -> ComparisonResult
groupCompare g1 g2 = with2Groups Internal.groupCompare enumFromCInt g1 g2

with2Groups :: Storable a => (Group -> Group -> Ptr a -> IO CInt) -> (a -> b) -> Group -> Group -> b
with2Groups prim build group1 group2 =
   unsafePerformIO $
      alloca $ \ptr -> do
         checkError $ prim group1 group2 ptr
         build <$> peek ptr

-- Technically it might make better sense to make the second argument a Set rather than a list
-- but the order is significant in the groupIncl function (the other function, not this one).
-- For the sake of keeping their types in sync, a list is used instead.
groupExcl :: Group -> [Rank] -> Group
groupExcl group ranks = groupWithRankList Internal.groupExcl group ranks

groupIncl :: Group -> [Rank] -> Group
groupIncl group ranks = groupWithRankList Internal.groupIncl group ranks

-- TODO: this (Ptr a) is really a (Ptr MPI_Group), only we dont want to export MPI_Group from Internal.chs
-- Should find a way to make typesig cleaner.
groupWithRankList :: (Group -> CInt -> Ptr CInt -> Ptr a -> IO CInt) -> Group -> [Rank] -> Group
groupWithRankList prim group ranks =
   unsafePerformIO $ do
      let (rankIntList :: [Int]) = map fromEnum ranks
      alloca $ \groupPtr ->
         withArrayLen rankIntList $ \size ranksPtr -> do
            checkError $ prim group (enumToCInt size) (castPtr ranksPtr) (castPtr groupPtr)
            MkGroup <$> peek groupPtr

groupTranslateRanks :: Group -> [Rank] -> Group -> [Rank]
groupTranslateRanks group1 ranks group2 =
   unsafePerformIO $ do
      let (rankIntList :: [Int]) = map fromEnum ranks
      withArrayLen rankIntList $ \size ranksPtr ->
         allocaArray size $ \resultPtr -> do
            checkError $ Internal.groupTranslateRanks group1 (enumToCInt size) (castPtr ranksPtr) group2 resultPtr
            map toRank <$> peekArray size resultPtr

-- | Return the number of bytes used to store an MPI 'Datatype'.
typeSize :: Datatype -> Int
typeSize dataType = unsafePerformIO $
   alloca $ \ptr -> do
      checkError $ Internal.typeSize dataType ptr
      fromIntegral <$> peek ptr

-- | Set the error handler for a communicator.
-- This function corresponds to MPI_Comm_set_errhandler.
commSetErrhandler :: Comm -> Errhandler -> IO ()
commSetErrhandler comm h = checkError $ Internal.commSetErrhandler comm h

-- | Get the error handler for a communicator.
-- This function corresponds to MPI_Comm_get_errhandler.
commGetErrhandler :: Comm -> IO Errhandler
commGetErrhandler comm =
   alloca $ \handlerPtr -> do
      checkError $ Internal.commGetErrhandler comm handlerPtr
      peek handlerPtr

-- | Error handler which causes errors from MPI functions to be raised as exceptions.
errorsThrowExceptions :: Errhandler
errorsThrowExceptions = errorsReturn

-- | Tries to terminate all MPI processes in its communicator argument.
-- The second argument is an error code which /may/ be used as the return status
-- of the MPI process, but this is not guaranteed. On systems where 'Int' has a larger
-- range than 'CInt', the error code will be clipped to fit into the range of 'CInt'.
-- This function corresponds to @MPI_Abort@.
abort :: Comm -> Int -> IO ()
abort comm code =
   checkError $ Internal.abort comm (toErrorCode code)
   where
   toErrorCode :: Int -> CInt
   toErrorCode i
      -- Assumes Int always has range at least as big as CInt.
      | i < (fromIntegral (minBound :: CInt)) = minBound
      | i > (fromIntegral (maxBound :: CInt)) = maxBound
      | otherwise = cIntConv i

{- $collectives-split
Collective operations in MPI usually take a large set of arguments
that include pointers to both input and output buffers. This fits
nicely in the C programming style:

 1. Pointers to send and receive buffers are declared

 2. if (my_rank == root) then (send buffer is allocated and filled)

 3. Both pointers are passed to collective function, which ignores
    unallocated send buffer for all non-root processes.

In Haskell there is no simple way to declare pointers to arrays or
values without allocating them and then do the allocation
laterr. Plus, authors wanted to
encourage users to partially apply API calls both for convenience (see
below) and for simplifying reuse of already-allocated arrays (also see
below).

Therefore it was decided to split most asymmetric collective calls in
two parts - sending and receiving. Thus @MPI_Gather@ is represented by
'gatherSend' and 'gatherRecv', and so on. -}

{- $arg-order 
Very often MPI programmer would find himself in the situation
where he wants to send/receive messages between the same processess
over and over again. This is true for both point-to-point modes of
communication and for collective operations.

Which is why we've chosen to change the order of arguments in most API
calls in a way that would make partial application of API calls
natural. For example, if your rank 0 process often sends single
message msg1 to rank 1 and various messages to rank 2, you could
define the following shortcuts:

@
sendMsg1 = send comm rank1 tag1 msg1
sendTo2 = send comm rank2
@
-}

{- $rank-checking
Collective operations that are split into separate send/recv parts
(see above) take "root rank" as an argument. Right now no safeguards
are in place to ensure that rank supplied to the send function is
corresponding to the rank of that process. We believe that it does not
worsen the general go-on-and-shoot-yourself-in-the-foot attitide of
the MPI API.
-}

{- $err-handling
Most MPI functions may fail with an error, which, by default, will cause
the program to abort. This can be changed by setting the error
handler to 'errorsThrowExceptions'. As the name suggests, this will
turn the error into an exception which can be handled using
the facilities provided by the "Control.Exception" module.
-}

{-$example
Below is a small but complete MPI program. Process 1 sends the message
@\"Hello World\"@ to process 0. Process 0 receives the message and prints it
to standard output. It assumes that there are at least 2 MPI processes
available; a more robust program would check this condition first, before
trying to send messages.

@
module Main where

import "Control.Parallel.MPI" (mpi, commRank, commWorld, unitTag)
import "Control.Parallel.MPI.Serializable" (send, recv)
import Control.Monad (when)

main :: IO ()
main = 'mpi' $ do
   rank <- 'commRank' 'commWorld'
   when (rank == 1) $
      'send' 'commWorld' 0 'unitTag' \"Hello World\"
   when (rank == 0) $ do
      (msg, _status) <- 'recv' 'commWorld' 1 'unitTag'
      putStrLn msg
@
-}