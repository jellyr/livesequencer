-- module GUI where

import qualified IO
import Term
import Module ( Module, source_location, source_text )
import Program
import Rewrite
import qualified Option

import Graphics.UI.WX as WX
import Control.Concurrent ( forkIO )
import Control.Concurrent.Chan
import Control.Concurrent.STM.TVar
import Control.Concurrent.STM.TMVar
import qualified Control.Monad.STM as STM

import qualified Graphics.UI.WXCore as WXCore
import qualified Graphics.UI.WXCore.WxcClassesMZ as WXCMZ
import Graphics.UI.WXCore.WxcDefs ( wxID_HIGHEST )
import Graphics.UI.WXCore.WxcClassesAL ( commandEventCreate, evtHandlerAddPendingEvent )

import Graphics.UI.WXCore.Events
import Event
import Common

import qualified Sound.ALSA.Sequencer as SndSeq

import qualified Control.Monad.Trans.State as MS
import Control.Monad.Trans.Writer ( runWriter )
import Control.Monad.IO.Class ( liftIO )
import Control.Monad ( forever, forM, forM_ )
import Text.ParserCombinators.Parsec ( parse )
import qualified Text.ParserCombinators.Parsec as Pos

import System.IO ( hPutStrLn, hSetBuffering, BufferMode(..), stderr )

import qualified Data.Map as M
import Data.Maybe ( maybeToList, fromMaybe )

import Data.Bool.HT ( if' )

import Prelude hiding ( log )


-- | read rules files, should contain definition for "main"
main :: IO ()
main = do
    hSetBuffering stderr LineBuffering
    opt <- Option.get
    p <- Program.chase (Option.importPaths opt) $ Option.moduleName opt

    input <- newChan
    output <- newChan
    withSequencer "Rewrite-Sequencer" $ \sq -> do
        void $ forkIO $ machine input output p sq
        gui input output p
        stopQueue sq


data Action =
     Modification (Identifier, String)
   | Execution Execution

data Execution = Restart | Stop | Pause | Continue

writeTMVar :: TMVar a -> a -> STM.STM ()
writeTMVar var a =
    tryTakeTMVar var >> putTMVar var a

{-
This runs concurrently
and is fed with changes to the modules by the GUI.
It parses them and provides the parsed modules to the execution engine.
Since parsing is a bit of work
we can keep the GUI and the execution of code going while parsing.
-}
machine :: Chan Action -- ^ machine reads program text from here
                   -- (module name, module contents)
        -> Chan ( [Message], String) -- ^ and writes output to here
                   -- (log message (for highlighting), current term)
        -> Program -- ^ initial program
        -> Sequencer SndSeq.DuplexMode
        -> IO ()
machine input output prog sq = do
    program <- newTVarIO prog
    let mainName = read "main"
    term <- newTMVarIO mainName

    void $ forkIO $ flip MS.evalStateT mainName $ forever $ do
        action <- liftIO $ readChan input
        let running b =
                let msg = Running b
                in  liftIO $ writeChan output ( [ msg ], show msg )
        case action of
            Execution exec ->
                case exec of
                    Restart -> do
                        running True
                        MS.put mainName
                        liftIO $ quietContinueQueue sq
                        liftIO $ void $ STM.atomically $ writeTMVar term mainName
                    Stop -> do
                        running False
                        liftIO $ stopQueue sq
                        liftIO $ void $ STM.atomically $ tryTakeTMVar term
                        MS.put mainName
                    Pause -> do
                        running False
                        liftIO $ pauseQueue sq
                        MS.put .
                            maybe mainName id
                            =<< (liftIO $ STM.atomically $ tryTakeTMVar term)
                    Continue -> do
                        running True
                        liftIO $ continueQueue sq
                        liftIO . STM.atomically . writeTMVar term
                            =<< MS.get
                        MS.put mainName
            Modification (moduleName, sourceCode) -> liftIO $ do
                hPutStrLn stderr $
                    "module " ++ show moduleName ++
                    " has new input\n" ++ sourceCode
                case parse IO.input ( show moduleName ) sourceCode of
                    Left err -> print err
                    Right m0 -> (STM.atomically $ do
                        -- TODO: handle the case that the module changed its name
                        -- (might happen if user changes the text in the editor)
                        p <- readTVar program
                        let Just previous = M.lookup moduleName $ modules p
                        let m = m0 { source_location = source_location previous
                                   , source_text = sourceCode
                                   }
                        writeTVar program $
                            p { modules =  M.insert moduleName m $ modules p })
                        >>
                        hPutStrLn stderr "parsed and modified OK"

    startQueue sq
    MS.evalStateT
        ( execute program term ( writeChan output ) sq ) 0


execute :: TVar Program
                  -- ^ current program (GUI might change the contents)
        -> TMVar Term -- ^ current term
        -> ( ( [Message], String) -> IO () ) -- ^ sink for messages (show current term)
        -> Sequencer SndSeq.DuplexMode -- ^ for playing MIDI events
        -> MS.StateT Time IO ()
execute program term output sq = forever $ do
    -- hPutStrLn stderr "execute"
    p <- liftIO $ readTVarIO program
        -- this happens anew at each click
        -- since the program text might have changed in the editor
    ( ( s, log ), result ) <- liftIO $ STM.atomically $ do
        slog@( s, _log ) <-
            fmap (runWriter . force_head p) $ takeTMVar term
        fmap ((,) slog) $
            case s of
                Node i [x, xs] | name i == ":" -> do
                    putTMVar term xs
                    return $ Right x
                Node i [] | name i == "[]" ->
                    return $ Left "finished."
                _ ->
                    return $ Left $
                    "I do not know how to handle this term:\n" ++ show s

    liftIO $ output $ ( log, show s )
    case result of
        Left msg -> liftIO $ do
            hPutStrLn stderr msg
            stopQueue sq
            output ( [ Running False ], "Running False" )
        Right x -> do
            play_event x sq
            case x of
                Node j _ | name j == "Wait" -> liftIO $
                    output ( [ Reset_Display ], "Reset_Display" )
                _ -> return ()


-- | following code taken from http://snipplr.com/view/17538/
myEventId :: Int
myEventId = wxID_HIGHEST+1 -- the custom event ID

-- | the custom event is registered as a menu event
createMyEvent :: IO (WXCore.CommandEvent ())
createMyEvent = commandEventCreate WXCMZ.wxEVT_COMMAND_MENU_SELECTED myEventId

registerMyEvent :: WXCore.EvtHandler a -> IO () -> IO ()
registerMyEvent win io = evtHandlerOnMenuCommand win myEventId io


-- might be moved to wx package
cursor :: Attr (TextCtrl a) Int
cursor =
    newAttr "cursor"
        WXCMZ.textCtrlGetInsertionPoint
        WXCMZ.textCtrlSetInsertionPoint

editable :: WriteAttr (TextCtrl a) Bool
editable =
    writeAttr "editable"
        WXCMZ.textCtrlSetEditable


gui :: Chan Action -- ^  the gui writes here
      -- (if the program text changes due to an edit action)
    -> Chan ([Message], String) -- ^ the machine writes here
      -- (a textual representation of "current expression")
    -> Program -- ^ initial texts for modules
    -> IO ()
gui input output pack = WX.start $ do
    f <- WX.frame
        [ text := "live-sequencer", visible := False
        ]

    out <- newChan

    void $ forkIO $ forever $ do
        writeChan out =<< readChan output
        evtHandlerAddPendingEvent f =<< createMyEvent

    p <- WX.panel f [ ]
    nb <- WX.notebook p [ ]

    let refreshProgram (path, editor, highlighter) = do
            s <- get editor text
            pos <- get editor cursor
            set highlighter [ text := s, cursor := pos ]
            writeChan input (Modification (path,s))

    runningButton <- WX.checkBox p
        [ text := "running",
          checked := True,
          tooltip :=
              "pause or continue program execution\n" ++
              "shortcut: Ctrl-U" ]


    panelsHls <- forM (M.toList $ modules pack) $ \ (path,content) -> do
        psub <- panel nb []
        editor <- textCtrl psub [ font := fontFixed ]
        highlighter <- textCtrlRich psub [ font := fontFixed, editable := False ]
        -- TODO: show status (modified in editor, sent to machine, saved to file)
        -- TODO: load/save actions
        let isRefreshKey k =
                -- Ctrl-R
                keyKey k == KeyChar '\018' && keyModifiers k == justControl
                -- Alt-R
                -- keyKey k == KeyChar 'r' && keyModifiers k == justAlt
            isRestartKey k =
                keyKey k == KeyChar '\020' && keyModifiers k == justControl
            isStopKey k =
                keyKey k == KeyChar '\026' && keyModifiers k == justControl
            isRunningKey k =
                keyKey k == KeyChar '\021' && keyModifiers k == justControl
        set editor
            [ text := source_text content
            , on keyboard :~ \defaultHandler k ->
                 -- print (case keyKey k of KeyChar c -> fromEnum c) >>
                 if' (isRefreshKey k)
                     (refreshProgram (path, editor, highlighter)) $
                 if' (isRestartKey k)
                     (writeChan input (Execution Restart)) $
                 if' (isStopKey k)
                     (writeChan input (Execution Stop)) $
                 if' (isRunningKey k)
                     (do running <- get runningButton checked
                         writeChan input . Execution $
                             if' running Pause Continue) $
                 defaultHandler k
            ]
        set highlighter [ text := source_text content ]
        return
           (tab ( show path ) $ container psub $ column 5 $
               map WX.fill $ [widget editor, widget highlighter],
            (path, editor, highlighter))

    let panels = map fst panelsHls
        highlighters = M.fromList $ map ( \ (_,(pnl,_,h)) -> (pnl, h) ) panelsHls

    refreshButton <- WX.button p
        [ text := "refresh",
          on command := mapM_ (refreshProgram . snd) panelsHls,
          tooltip :=
              "parse the edited program and if successful\n" ++
              "replace the executed program\n" ++
              "shortcut: Ctrl-R" ]
    restartButton <- WX.button p
        [ text := "restart",
          on command := writeChan input (Execution Restart),
          tooltip :=
              "restart program execution with 'main'\n" ++
              "shortcut: Ctrl-T" ]
    stopButton <- WX.button p
        [ text := "stop",
          on command := writeChan input (Execution Stop),
          tooltip :=
              "stop program execution\n" ++
              "shortcut: Ctrl-Z" ]
    set runningButton
        [ on command := do
              running <- get runningButton checked
              writeChan input . Execution $
                  if running then Continue else Pause ]

    reducer <- textCtrl p [ font := fontFixed, editable := False ]


    highlights <- varCreate M.empty

    registerMyEvent f $ do
        (log,sr) <- readChan out
        let setColorHighlighters ::
                M.Map Identifier [Identifier] -> Int -> Int -> Int -> IO ()
            setColorHighlighters m r g b =
                set_color nb highlighters m ( rgb r g b )
        void $ forM log $ \ msg -> do
          case msg of
            Step { } -> do
                set reducer [ text := sr ]

                let m = M.fromList $ do
                      t <- target msg : maybeToList ( Rewrite.rule msg )
                      (ident,_) <-
                          reads $ Pos.sourceName $ Term.start t
                      return (ident, [t])
                void $ varUpdate highlights $ M.unionWith (++) m
                setColorHighlighters m 0 200 200

            Data { } -> do
                set reducer [ text := sr ]

                let t = origin msg
                    m = M.fromList $ do
                      (ident,_) <-
                          reads $ Pos.sourceName $ Term.start t
                      return (ident, [t])
                void $ varUpdate highlights $ M.unionWith (++) m
                setColorHighlighters m 200 200 0

            Reset_Display -> do
                previous <- varSwap highlights M.empty
                setColorHighlighters previous 255 255 255

            Running running -> do
                set runningButton [ checked := running ]

    set f [ layout := container p $ margin 5
            $ column 5
            [ WX.hfill $ row 5 $
                  [widget refreshButton,
                   widget restartButton, widget stopButton, widget runningButton]
            , WX.fill $ tabs nb panels
            , WX.fill $ widget reducer
            ]
            , visible := True
            , clientSize := sz 500 300
          ]

set_color ::
    (Ord k) =>
    Notebook a ->
    M.Map k (TextCtrl a) ->
    M.Map k [Identifier] ->
    Color ->
    IO ()
set_color nb highlighters positions hicolor = void $ do
    index <- WXCMZ.notebookGetSelection nb
    let (p, highlighter) = M.toList highlighters !! index
    attr <- WXCMZ.textCtrlGetDefaultStyle highlighter
    bracket
        (WXCMZ.textAttrGetBackgroundColour attr)
        (WXCMZ.textAttrSetBackgroundColour attr) $ const $ do
            WXCMZ.textAttrSetBackgroundColour attr hicolor
            forM_ (fromMaybe [] $ M.lookup p positions) $ \ ident -> do
                let mkpos pos =
                       WXCMZ.textCtrlXYToPosition highlighter
                          $ Point (Pos.sourceColumn pos - 1)
                                  (Pos.sourceLine   pos - 1)
                from <- mkpos $ Term.start ident
                to   <- mkpos $ Term.end ident
                WXCMZ.textCtrlSetStyle highlighter from to attr
