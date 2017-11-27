{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE MultiParamTypeClasses #-}

module Network.Mattermost.Types where

import           Control.Applicative
import           Text.Printf ( PrintfArg(..), printf )
import           Data.Hashable ( Hashable )
import qualified Data.Aeson as A
import           Data.Aeson ( (.:), (.=), (.:?), (.!=) )
import           Data.Aeson.Types ( ToJSONKey
                                  , FromJSONKey
                                  , FromJSON
                                  , ToJSON
                                  , Parser
                                  , typeMismatch
                                  )
import qualified Data.HashMap.Strict as HM
import           Data.Monoid ( (<>) )
import           Data.Ratio ( (%) )
import           Data.Sequence (Seq)
import qualified Data.Sequence as S
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Time.Clock ( UTCTime, getCurrentTime )
import           Data.Time.Clock.POSIX ( posixSecondsToUTCTime
                                       , utcTimeToPOSIXSeconds )
import           Network.Connection (ConnectionContext, initConnectionContext)
import           Network.Mattermost.Types.Base
import           Network.Mattermost.Types.Internal

runLogger :: ConnectionData -> String -> LogEventType -> IO ()
runLogger ConnectionData { cdLogger = Just l } n ev =
  l (LogEvent n ev)
runLogger _ _ _ = return ()

runLoggerS :: Session -> String -> LogEventType -> IO ()
runLoggerS (Session cd _) = runLogger cd

maybeFail :: Parser a -> Parser (Maybe a)
maybeFail p = (Just <$> p) <|> (return Nothing)

-- | Creates a structure representing a TLS connection to the server.
mkConnectionData :: Hostname -> Port -> ConnectionContext -> ConnectionData
mkConnectionData host port ctx = ConnectionData
  { cdHostname      = host
  , cdPort          = port
  , cdConnectionCtx = ctx
  , cdAutoClose     = Yes
  , cdToken         = Nothing
  , cdLogger        = Nothing
  , cdUseTLS        = True
  }

-- | Plaintext HTTP instead of a TLS connection.
mkConnectionDataInsecure :: Hostname -> Port -> ConnectionContext -> ConnectionData
mkConnectionDataInsecure host port ctx = ConnectionData
  { cdHostname      = host
  , cdPort          = port
  , cdConnectionCtx = ctx
  , cdAutoClose     = Yes
  , cdToken         = Nothing
  , cdLogger        = Nothing
  , cdUseTLS        = False
  }

initConnectionData :: Hostname -> Port -> IO ConnectionData
initConnectionData host port = do
  ctx <- initConnectionContext
  return (mkConnectionData host port ctx)

initConnectionDataInsecure :: Hostname -> Port -> IO ConnectionData
initConnectionDataInsecure host port = do
  ctx <- initConnectionContext
  return (mkConnectionDataInsecure host port ctx)

withLogger :: ConnectionData -> Logger -> ConnectionData
withLogger cd logger = cd { cdLogger = Just logger }

noLogger :: ConnectionData -> ConnectionData
noLogger cd = cd { cdLogger = Nothing }

data Session = Session
  { sessConn :: ConnectionData
  , sessTok  :: Token
  }

mkSession :: ConnectionData -> Token -> Session
mkSession = Session

--

data Login
  = Login
  { username :: Text
  , password :: Text
  }

instance A.ToJSON Login where
  toJSON l = A.object ["login_id" A..= username l
                      ,"password" A..= password l
                      ]


data SetChannelHeader = SetChannelHeader
  { setChannelHeaderChanId :: ChannelId
  , setChannelHeaderString :: Text
  }

instance A.ToJSON SetChannelHeader where
  toJSON (SetChannelHeader cId p) =
      A.object ["channel_id" A..= cId
               ,"channel_header" A..= p
               ]

data Type = Ordinary
          | Direct
          | Private
          | Group
          | Unknown Text
  deriving (Read, Show, Ord, Eq)

instance A.FromJSON Type where
  parseJSON = A.withText "Type" $ \t ->
      return $ if | t == "O"  -> Ordinary
                  | t == "D"  -> Direct
                  | t == "P"  -> Private
                  | t == "G"  -> Group
                  | otherwise -> Unknown t

instance A.ToJSON Type where
  toJSON Direct              = A.toJSON ("D"::Text)
  toJSON Ordinary            = A.toJSON ("O"::Text)
  toJSON Private             = A.toJSON ("P"::Text)
  toJSON Group     = A.toJSON ("G"::Text)
  toJSON (Unknown t)         = A.toJSON t

--

-- For converting from type specific Id to generic Id
class IsId x where
  toId   :: x  -> Id
  fromId :: Id -> x

class HasId x y | x -> y where
  getId :: x -> y

newtype Id = Id { unId :: Text }
  deriving (Read, Show, Eq, Ord, Hashable, ToJSON, ToJSONKey, FromJSONKey)

idString :: IsId x => x -> Text
idString x = unId i
  where i = toId x

instance A.FromJSON Id where
  parseJSON = A.withText "Id" $ \t ->
      case T.null t of
          False -> return $ Id t
          True -> fail "Empty ID"

instance IsId Id where
  toId   = id
  fromId = id

instance HasId Id Id where
  getId  = id

--

newtype TeamId = TI { unTI :: Id }
  deriving (Read, Show, Eq, Ord, Hashable, ToJSON, ToJSONKey, FromJSONKey, FromJSON)

instance IsId TeamId where
  toId   = unTI
  fromId = TI

instance PrintfArg TeamId where
  formatArg = formatArg . idString

data Team
  = Team
  { teamId              :: TeamId
  , teamCreateAt        :: UTCTime
  , teamUpdateAt        :: UTCTime
  , teamDeleteAt        :: UTCTime
  , teamDisplayName     :: Text
  , teamName            :: Text
  , teamEmail           :: Text
  , teamType            :: Type
  , teamCompanyName     :: Text
  , teamAllowedDomains  :: Text
  , teamInviteId        :: Id
  , teamAllowOpenInvite :: Bool
  }
  deriving (Read, Show, Eq, Ord)

instance HasId Team TeamId where
  getId = teamId

instance A.FromJSON Team where
  parseJSON = A.withObject "Team" $ \v -> do
    teamId              <- v .: "id"
    teamCreateAt        <- millisecondsToUTCTime <$> v .: "create_at"
    teamUpdateAt        <- millisecondsToUTCTime <$> v .: "update_at"
    teamDeleteAt        <- millisecondsToUTCTime <$> v .: "delete_at"
    teamDisplayName     <- v .: "display_name"
    teamName            <- v .: "name"
    teamEmail           <- v .: "email"
    teamType            <- v .: "type"
    teamCompanyName     <- v .: "company_name"
    teamAllowedDomains  <- v .: "allowed_domains"
    teamInviteId        <- v .: "invite_id"
    teamAllowOpenInvite <- v .: "allow_open_invite"
    return Team { .. }

data TeamMember = TeamMember
  { teamMemberUserId :: UserId
  , teamMemberTeamId :: TeamId
  , teamMemberRoles  :: Text
  } deriving (Read, Show, Eq, Ord)

instance A.FromJSON TeamMember where
  parseJSON = A.withObject "TeamMember" $ \v -> do
    teamMemberUserId <- v .: "user_id"
    teamMemberTeamId <- v .: "team_id"
    teamMemberRoles  <- v .: "roles"
    return TeamMember { .. }

--

data WithDefault a
  = IsValue a
  | Default
    deriving (Read, Show, Eq, Ord)

instance A.FromJSON t => A.FromJSON (WithDefault t) where
  parseJSON (A.String "default") = return Default
  parseJSON t                    = IsValue <$> A.parseJSON t

instance Functor WithDefault where
  fmap f (IsValue x) = IsValue (f x)
  fmap _ Default     = Default

data NotifyOption
  = NotifyOptionAll
  | NotifyOptionMention
  | NotifyOptionNone
    deriving (Read, Show, Eq, Ord)

instance A.FromJSON NotifyOption where
  parseJSON (A.String "all")     = return NotifyOptionAll
  parseJSON (A.String "mention") = return NotifyOptionMention
  parseJSON (A.String "none")    = return NotifyOptionNone
  parseJSON xs                   = fail ("Unknown NotifyOption value: " ++ show xs)

data UserNotifyProps = UserNotifyProps
  { userNotifyPropsMentionKeys  :: [Text]
  , userNotifyPropsEmail        :: Bool
  , userNotifyPropsPush         :: NotifyOption
  , userNotifyPropsDesktop      :: NotifyOption
  , userNotifyPropsDesktopSound :: Bool
  , userNotifyPropsChannel      :: Bool
  , userNotifyPropsFirstName    :: Bool
  } deriving (Eq, Show, Read, Ord)

data ChannelNotifyProps = ChannelNotifyProps
  { channelNotifyPropsEmail      :: WithDefault Bool
  , channelNotifyPropsDesktop    :: WithDefault NotifyOption
  , channelNotifyPropsPush       :: WithDefault NotifyOption
  , channelNotifyPropsMarkUnread :: WithDefault NotifyOption
  } deriving (Eq, Show, Read, Ord)

emptyUserNotifyProps :: UserNotifyProps
emptyUserNotifyProps = UserNotifyProps
  { userNotifyPropsMentionKeys  = []
  , userNotifyPropsEmail        = False
  , userNotifyPropsPush         = NotifyOptionNone
  , userNotifyPropsDesktop      = NotifyOptionNone
  , userNotifyPropsDesktopSound = False
  , userNotifyPropsChannel      = False
  , userNotifyPropsFirstName    = False
  }

emptyChannelNotifyProps :: ChannelNotifyProps
emptyChannelNotifyProps = ChannelNotifyProps
  { channelNotifyPropsEmail      = Default
  , channelNotifyPropsPush       = Default
  , channelNotifyPropsDesktop    = Default
  , channelNotifyPropsMarkUnread = Default
  }

newtype BoolString = BoolString { fromBoolString :: Bool }

instance A.FromJSON BoolString where
  parseJSON = A.withText "bool as string" $ \v ->
    case v of
      "true"  -> return (BoolString True)
      "false" -> return (BoolString False)
      _       -> fail "Expected \"true\" or \"false\""

instance A.FromJSON UserNotifyProps where
  parseJSON = A.withObject "UserNotifyProps" $ \v -> do
    userNotifyPropsMentionKeys  <- T.split (==',') <$>
                                     (v .:? "mention_keys" .!= "")
    userNotifyPropsPush         <- v .:? "push" .!= NotifyOptionMention
    userNotifyPropsDesktop      <- v .:? "desktop" .!= NotifyOptionAll
    userNotifyPropsEmail        <- fromBoolString <$> (v .:? "email"         .!= BoolString True)
    userNotifyPropsDesktopSound <- fromBoolString <$> (v .:? "desktop_sound" .!= BoolString True)
    userNotifyPropsChannel      <- fromBoolString <$> (v .:? "channel"       .!= BoolString True)
    userNotifyPropsFirstName    <- fromBoolString <$> (v .:? "first_name"    .!= BoolString False)
    return UserNotifyProps { .. }

instance A.FromJSON ChannelNotifyProps where
  parseJSON = A.withObject "ChannelNotifyProps" $ \v -> do
    channelNotifyPropsEmail      <- fmap fromBoolString <$>
                                    (v .:? "email" .!= IsValue (BoolString True))
    channelNotifyPropsPush       <- v .:? "push" .!= IsValue NotifyOptionMention
    channelNotifyPropsDesktop    <- v .:? "desktop" .!= IsValue NotifyOptionAll
    channelNotifyPropsMarkUnread <- v .:? "mark_unread" .!= IsValue NotifyOptionAll
    return ChannelNotifyProps { .. }

--

newtype ChannelId = CI { unCI :: Id }
  deriving (Read, Show, Eq, Ord, Hashable, ToJSON, ToJSONKey, FromJSONKey, FromJSON)

instance IsId ChannelId where
  toId   = unCI
  fromId = CI

instance PrintfArg ChannelId where
  formatArg = formatArg . idString

data Channel
  = Channel
  { channelId            :: ChannelId
  , channelCreateAt      :: UTCTime
  , channelUpdateAt      :: UTCTime
  , channelDeleteAt      :: UTCTime
  , channelTeamId        :: Maybe TeamId
  , channelType          :: Type
  , channelDisplayName   :: Text
  , channelName          :: Text
  , channelHeader        :: Text
  , channelPurpose       :: Text
  , channelLastPostAt    :: UTCTime
  , channelTotalMsgCount :: Int
  , channelExtraUpdateAt :: UTCTime
  , channelCreatorId     :: Maybe UserId
  } deriving (Read, Show, Eq, Ord)

instance HasId Channel ChannelId where
  getId = channelId

instance A.FromJSON Channel where
  parseJSON = A.withObject "Channel" $ \v -> do
    channelId              <- v .: "id"
    channelCreateAt        <- millisecondsToUTCTime <$> v .: "create_at"
    channelUpdateAt        <- millisecondsToUTCTime <$> v .: "update_at"
    channelDeleteAt        <- millisecondsToUTCTime <$> v .: "delete_at"
    channelTeamId          <- maybeFail (v .: "team_id")
    channelType            <- v .: "type"
    channelDisplayName     <- v .: "display_name"
    channelName            <- v .: "name"
    channelHeader          <- v .: "header"
    channelPurpose         <- v .: "purpose"
    channelLastPostAt      <- millisecondsToUTCTime <$> v .: "last_post_at"
    channelTotalMsgCount   <- v .: "total_msg_count"
    channelExtraUpdateAt   <- millisecondsToUTCTime <$> v .: "extra_update_at"
    channelCreatorId       <- maybeFail (v .: "creator_id")
    return Channel { .. }

-- This type only exists so that we can strip off the
-- outer most layer in mmGetChannel. See the
-- FromJSON instance.
newtype SingleChannel = SC Channel
  deriving (Read, Show, Eq, Ord)

instance A.FromJSON SingleChannel where
  parseJSON = A.withObject "SingleChannel" $ \v -> do
    channel <- v .: "channel"
    return (SC channel)

instance HasId ChannelData ChannelId where
  getId = channelDataChannelId

data ChannelData
  = ChannelData
  { channelDataChannelId    :: ChannelId
  , channelDataUserId       :: UserId
  , channelDataRoles        :: Text
  , channelDataLastViewedAt :: UTCTime
  , channelDataMsgCount     :: Int
  , channelDataMentionCount :: Int
  , channelDataNotifyProps  :: ChannelNotifyProps
  , channelDataLastUpdateAt :: UTCTime
  } deriving (Read, Show, Eq)

instance A.FromJSON ChannelData where
  parseJSON = A.withObject "ChannelData" $ \o -> do
    channelDataChannelId <- o .: "channel_id"
    channelDataUserId    <- o .: "user_id"
    channelDataRoles     <- o .: "roles"
    channelDataLastViewedAt <- millisecondsToUTCTime <$> o .: "last_viewed_at"
    channelDataMsgCount     <- o .: "msg_count"
    channelDataMentionCount <- o .: "mention_count"
    channelDataNotifyProps  <- o .: "notify_props"
    channelDataLastUpdateAt <- millisecondsToUTCTime <$> o .: "last_update_at"
    return ChannelData { .. }

data ChannelWithData = ChannelWithData Channel ChannelData
  deriving (Read, Show, Eq)

instance A.FromJSON ChannelWithData where
  parseJSON (A.Object v) =
      ChannelWithData <$> (v .: "channel")
                      <*> (v .: "member")
  parseJSON v = typeMismatch "Invalid channel/data pair " v

type Channels = Seq Channel

data MinChannel = MinChannel
  { minChannelName        :: Text
  , minChannelDisplayName :: Text
  , minChannelPurpose     :: Maybe Text
  , minChannelHeader      :: Maybe Text
  , minChannelType        :: Type
  } deriving (Read, Eq, Show)

instance A.ToJSON MinChannel where
  toJSON MinChannel { .. }  = A.object $
    [ "name"         .= minChannelName
    , "display_name" .= minChannelDisplayName
    , "type"         .= minChannelType
    ] ++
    [ "purpose" .= p | Just p <- [minChannelPurpose] ] ++
    [ "header"  .= h | Just h <- [minChannelHeader] ]
--

newtype UserId = UI { unUI :: Id }
  deriving (Read, Show, Eq, Ord, Hashable, ToJSON, ToJSONKey, FromJSONKey, FromJSON)

instance IsId UserId where
  toId   = unUI
  fromId = UI

instance PrintfArg UserId where
  formatArg = formatArg . idString

--

-- Note: there's lots of other stuff in an initial_load response but
-- this is what we use for now.
data InitialLoad
  = InitialLoad
  { initialLoadUser :: User
  , initialLoadTeams :: Seq Team
  } deriving (Eq, Show)

instance A.FromJSON InitialLoad where
  parseJSON = A.withObject "InitialLoad" $ \o -> do
    initialLoadUser        <- o .: "user"
    initialLoadTeams       <- o .: "teams"
    return InitialLoad { .. }

--

instance HasId User UserId where
  getId = userId

data User
  = User
  { userId                 :: UserId
  , userCreateAt           :: UTCTime
  , userUpdateAt           :: UTCTime
  , userDeleteAt           :: UTCTime
  , userUsername           :: Text
  , userAuthData           :: Text
  , userAuthService        :: Text
  , userEmail              :: Text
  , userEmailVerified      :: Bool
  , userNickname           :: Text
  , userFirstName          :: Text
  , userLastName           :: Text
  , userRoles              :: Text
  , userNotifyProps        :: UserNotifyProps
  , userLastPasswordUpdate :: Maybe UTCTime
  , userLastPictureUpdate  :: Maybe UTCTime
  , userLocale             :: Text
  } deriving (Read, Show, Eq)

instance A.FromJSON User where
  parseJSON = A.withObject "User" $ \o -> do
    userId                 <- o .: "id"
    userCreateAt           <- millisecondsToUTCTime <$> o .: "create_at"
    userUpdateAt           <- millisecondsToUTCTime <$> o .: "update_at"
    userDeleteAt           <- millisecondsToUTCTime <$> o .: "delete_at"
    userUsername           <- o .:  "username"
    userAuthData           <- o .:  "auth_data"
    userAuthService        <- o .:  "auth_service"
    userEmail              <- o .:  "email"
    userEmailVerified      <- o .:? "email_verified" .!= False
    userNickname           <- o .:  "nickname"
    userFirstName          <- o .:  "first_name"
    userLastName           <- o .:  "last_name"
    userRoles              <- o .:  "roles"
    userNotifyProps        <- o .:? "notify_props" .!= emptyUserNotifyProps
    userLastPasswordUpdate <- (millisecondsToUTCTime <$>) <$>
                              (o .:? "last_password_update")
    userLastPictureUpdate  <- (millisecondsToUTCTime <$>) <$> (o .:? "last_picture_update")
    userLocale             <- o .: "locale"
    return User { .. }

-- The PostPropAttachment and PostPropAttachmentField types are
-- actually defined by Slack, and simply used by Mattermost; the
-- description of these fields can be found in this document:
-- https://api.slack.com/docs/message-attachments

data PostPropAttachmentField = PostPropAttachmentField
  { ppafTitle :: Text
  , ppafValue :: Text
  , ppafShort :: Bool
  } deriving (Read, Show, Eq)

instance A.FromJSON PostPropAttachmentField where
  parseJSON = A.withObject "PostPropAttachmentField" $ \v -> do
    ppafTitle <- v .: "title"
    ppafValue <- v .: "value"
    ppafShort <- v .: "short"
    return PostPropAttachmentField { .. }

data PostPropAttachment
  = PostPropAttachment
  { ppaId         :: Int
  , ppaFallback   :: Text
  , ppaColor      :: Text
  , ppaPretext    :: Text
  , ppaAuthorName :: Text
  , ppaAuthorLink :: Text
  , ppaAuthorIcon :: Text
  , ppaTitle      :: Text
  , ppaTitleLink  :: Text
  , ppaText       :: Text
  , ppaFields     :: Seq PostPropAttachmentField
  , ppaImageURL   :: Text
  , ppaThumbURL   :: Text
  , ppaFooter     :: Text
  , ppaFooterIcon :: Text
  } deriving (Read, Show, Eq)

instance A.FromJSON PostPropAttachment where
  parseJSON = A.withObject "Attachment" $ \v -> do
    let x .:?? f = x .: f <|> return mempty
    ppaId         <- v .: "id" <|> return 0
    ppaFallback   <- v .:?? "fallback"
    ppaColor      <- v .:?? "color"
    ppaPretext    <- v .:?? "pretext"
    ppaAuthorName <- v .:?? "author_name"
    ppaAuthorLink <- v .:?? "author_link"
    ppaAuthorIcon <- v .:?? "author_icon"
    ppaTitle      <- v .:?? "title"
    ppaTitleLink  <- v .:?? "title_link"
    ppaText       <- v .:?? "text"
    ppaFields     <- v .:?? "fields"
    ppaImageURL   <- v .:?? "image_url"
    ppaThumbURL   <- v .:?? "thumb_url"
    ppaFooter     <- v .:?? "footer"
    ppaFooterIcon <- v .:?? "footer_icon"
    return PostPropAttachment { .. }

instance A.ToJSON PostPropAttachment where
  toJSON PostPropAttachment { .. } = A.object
    [ "color" .= ppaColor
    , "text"  .= ppaText
    ]

data PostProps
  = PostProps
  { postPropsOverrideIconUrl  :: Maybe Text
  , postPropsOverrideUsername :: Maybe Text
  , postPropsAttachments      :: Maybe (Seq PostPropAttachment) -- A.Value
  , postPropsNewHeader        :: Maybe Text
  , postPropsOldHeader        :: Maybe Text
  } deriving (Read, Show, Eq)

instance A.FromJSON PostProps where
  parseJSON = A.withObject "Props" $ \v -> do
    postPropsOverrideIconUrl  <- v .:? "override_icon_url"
    postPropsOverrideUsername <- v .:? "override_username"
    postPropsAttachments      <- v .:? "attachments"
    postPropsNewHeader        <- v .:? "new_header"
    postPropsOldHeader        <- v .:? "old_header"
    return PostProps { .. }

instance A.ToJSON PostProps where
  toJSON PostProps { .. } = A.object $
    [ "override_icon_url" .= v | Just v <- [postPropsOverrideIconUrl ] ] ++
    [ "override_username" .= v | Just v <- [postPropsOverrideUsername] ] ++
    [ "attachments"       .= v | Just v <- [postPropsAttachments     ] ] ++
    [ "new_header"        .= v | Just v <- [postPropsNewHeader       ] ] ++
    [ "old_header"        .= v | Just v <- [postPropsOldHeader       ] ]

newtype PostId = PI { unPI :: Id }
  deriving (Read, Show, Eq, Ord, Hashable, ToJSON, ToJSONKey, FromJSONKey, FromJSON)

instance IsId PostId where
  toId   = unPI
  fromId = PI

instance PrintfArg PostId where
  formatArg = formatArg . idString

newtype FileId = FI { unFI :: Id }
  deriving (Read, Show, Eq, Ord, Hashable, ToJSON, ToJSONKey, FromJSONKey, FromJSON)

instance IsId FileId where
  toId = unFI
  fromId = FI

instance PrintfArg FileId where
  formatArg = formatArg . idString

urlForFile :: FileId -> Text
urlForFile fId =
  "/api/v3/files/" <> idString fId <> "/get"

data PostType
  = PostTypeJoinChannel
  | PostTypeLeaveChannel
  | PostTypeAddToChannel
  | PostTypeRemoveFromChannel
  | PostTypeHeaderChange
  | PostTypeDisplayNameChange
  | PostTypePurposeChange
  | PostTypeChannelDeleted
  | PostTypeEphemeral
  | PostTypeUnknown T.Text
    deriving (Read, Show, Eq)

instance A.FromJSON PostType where
  parseJSON = A.withText "Post type" $ \ t -> return $ case t of
    "system_join_channel"        -> PostTypeJoinChannel
    "system_leave_channel"       -> PostTypeLeaveChannel
    "system_add_to_channel"      -> PostTypeAddToChannel
    "system_remove_from_channel" -> PostTypeRemoveFromChannel
    "system_header_change"       -> PostTypeHeaderChange
    "system_displayname_change"  -> PostTypeDisplayNameChange
    "system_purpose_change"      -> PostTypePurposeChange
    "system_channel_deleted"     -> PostTypeChannelDeleted
    "system_ephemeral"           -> PostTypeEphemeral
    _                            -> PostTypeUnknown t

instance A.ToJSON PostType where
  toJSON typ = A.String $ case typ of
    PostTypeJoinChannel       -> "system_join_channel"
    PostTypeLeaveChannel      -> "system_leave_channel"
    PostTypeAddToChannel      -> "system_add_to_channel"
    PostTypeRemoveFromChannel -> "system_remove_from_channel"
    PostTypeHeaderChange      -> "system_header_change"
    PostTypeDisplayNameChange -> "system_displayname_change"
    PostTypePurposeChange     -> "system_purpose_change"
    PostTypeChannelDeleted    -> "system_channel_deleted"
    PostTypeEphemeral         -> "system_ephemeral"
    PostTypeUnknown t         -> t

data Post
  = Post
  { postPendingPostId :: Maybe PostId
  , postOriginalId    :: Maybe PostId
  , postProps         :: PostProps
  , postRootId        :: Maybe PostId
  , postFileIds       :: Seq FileId
  , postId            :: PostId
  , postType          :: PostType
  , postMessage       :: Text
  , postDeleteAt      :: Maybe UTCTime
  , postHashtags      :: Text
  , postUpdateAt      :: UTCTime
  , postUserId        :: Maybe UserId
  , postCreateAt      :: UTCTime
  , postParentId      :: Maybe PostId
  , postChannelId     :: ChannelId
  , postHasReactions  :: Bool
  } deriving (Read, Show, Eq)

instance HasId Post PostId where
  getId = postId

instance A.FromJSON Post where
  parseJSON = A.withObject "Post" $ \v -> do
    postPendingPostId <- maybeFail (v .: "pending_post_id")
    postOriginalId    <- maybeFail (v .: "original_id")
    postProps         <- v .: "props"
    postRootId        <- maybeFail (v .: "root_id")
    postFileIds       <- (v .: "file_ids") <|> (return mempty)
    postId            <- v .: "id"
    postType          <- v .: "type"
    postMessage       <- v .: "message"
    postDeleteAt      <- (millisecondsToUTCTime <$>) <$> v .:? "delete_at"
    postHashtags      <- v .: "hashtags"
    postUpdateAt      <- millisecondsToUTCTime <$> v .: "update_at"
    postUserId        <- maybeFail (v .: "user_id")
    postCreateAt      <- millisecondsToUTCTime <$> v .: "create_at"
    postParentId      <- maybeFail (v .: "parent_id")
    postChannelId     <- v .: "channel_id"
    postHasReactions  <- (v .: "has_reactions") <|> (return False)
    return Post { .. }

instance A.ToJSON Post where
  toJSON Post { .. } = A.object
    [ "pending_post_id" .= postPendingPostId
    , "original_id"     .= postOriginalId
    , "props"           .= postProps
    , "root_id"         .= postRootId
    , "file_ids"        .= postFileIds
    , "id"              .= postId
    , "type"            .= postType
    , "message"         .= postMessage
    , "delete_at"       .= (utcTimeToMilliseconds <$> postDeleteAt)
    , "hashtags"        .= postHashtags
    , "update_at"       .= utcTimeToMilliseconds postUpdateAt
    , "user_id"         .= postUserId
    , "create_at"       .= utcTimeToMilliseconds postCreateAt
    , "parent_id"       .= postParentId
    , "channel_id"      .= postChannelId
    , "has_reactions"   .= postHasReactions
    ]

data PendingPost
  = PendingPost
  { pendingPostChannelId :: ChannelId
  , pendingPostCreateAt  :: Maybe UTCTime
  , pendingPostFilenames :: Seq FilePath
  , pendingPostMessage   :: Text
  , pendingPostId        :: PendingPostId
  , pendingPostUserId    :: UserId
  , pendingPostParentId  :: Maybe PostId
  , pendingPostRootId    :: Maybe PostId
  } deriving (Read, Show, Eq)

instance A.ToJSON PendingPost where
  toJSON post = A.object
    [ "channel_id"      .= pendingPostChannelId post
    , "create_at"       .= maybe 0 utcTimeToMilliseconds (pendingPostCreateAt post)
    , "filenames"       .= pendingPostFilenames post
    , "message"         .= pendingPostMessage   post
    , "pending_post_id" .= pendingPostId        post
    , "user_id"         .= pendingPostUserId    post
    , "root_id"         .= pendingPostRootId    post
    , "parent_id"       .= pendingPostParentId  post
    ]

newtype PendingPostId = PPI { unPPI :: Id }
  deriving (Read, Show, Eq, Ord, Hashable, ToJSON, ToJSONKey, FromJSONKey, FromJSON)

instance IsId PendingPostId where
  toId   = unPPI
  fromId = PPI

instance HasId PendingPost PendingPostId where
  getId = pendingPostId

mkPendingPost :: Text -> UserId -> ChannelId -> IO PendingPost
mkPendingPost msg userid channelid = do
  now <- getCurrentTime
  let ms  = utcTimeToMilliseconds now :: Int
      pid = T.pack $ printf "%s:%d" (idString userid) ms
  return PendingPost
    { pendingPostId        = PPI (Id pid)
    , pendingPostChannelId = channelid
    , pendingPostCreateAt  = Nothing
    , pendingPostFilenames = S.empty
    , pendingPostMessage   = msg
    , pendingPostUserId    = userid
    , pendingPostRootId    = Nothing
    , pendingPostParentId  = Nothing
    }

data FileInfo
  = FileInfo
  { fileInfoId         :: FileId
  , fileInfoUserId     :: UserId
  , fileInfoPostId     :: Maybe PostId
  , fileInfoCreateAt   :: UTCTime
  , fileInfoUpdateAt   :: UTCTime
  , fileInfoDeleteAt   :: UTCTime
  , fileInfoName       :: Text
  , fileInfoExtension  :: Text
  , fileInfoSize       :: Int
  , fileInfoMimeType   :: Text
  , fileInfoWidth      :: Maybe Int
  , fileInfoHeight     :: Maybe Int
  , fileInfoHasPreview :: Bool
  } deriving (Read, Show, Eq)

instance ToJSON FileInfo where
  toJSON = undefined

instance FromJSON FileInfo where
  parseJSON = A.withObject "file_info" $ \o -> do
    fileInfoId         <- o .: "id"
    fileInfoUserId     <- o .: "user_id"
    fileInfoPostId     <- o .: "post_id"
    fileInfoCreateAt   <- millisecondsToUTCTime <$> o .: "create_at"
    fileInfoUpdateAt   <- millisecondsToUTCTime <$> o .: "update_at"
    fileInfoDeleteAt   <- millisecondsToUTCTime <$> o .: "delete_at"
    fileInfoName       <- o .: "name"
    fileInfoExtension  <- o .: "extension"
    fileInfoSize       <- o .: "size"
    fileInfoMimeType   <- o .: "mime_type"
    fileInfoWidth      <- o .:? "width"
    fileInfoHeight     <- o .:? "height"
    fileInfoHasPreview <- (o .: "has_preview_image") <|> pure False
    return FileInfo { .. }

--

data Posts
  = Posts
  { postsPosts :: HM.HashMap PostId Post
  , postsOrder :: Seq PostId
  } deriving (Read, Show, Eq)

instance A.FromJSON Posts where
  parseJSON = A.withObject "Posts" $ \v -> do
    postsPosts <- v .:? "posts" .!= HM.empty
    postsOrder <- v .:  "order"
    return Posts { .. }

--

millisecondsToUTCTime :: Integer -> UTCTime
millisecondsToUTCTime ms = posixSecondsToUTCTime (fromRational (ms%1000))

utcTimeToMilliseconds :: UTCTime -> Int
utcTimeToMilliseconds utc = truncate ((utcTimeToPOSIXSeconds utc)*1000)

--

data MinCommand
  = MinCommand
  { minComChannelId :: ChannelId
  , minComCommand   :: Text
  , minComParentId  :: Maybe PostId
  , minComRootId    :: Maybe PostId
  } deriving (Read, Show, Eq)

instance A.ToJSON MinCommand where
  toJSON MinCommand { .. } = A.object
    [ "channel_id" .= minComChannelId
    , "command"   .= minComCommand
    , "parent_id" .= minComParentId
    , "root_id" .= minComRootId
    ]

--

data Command
  = Command
  { commandId               :: CommandId
  , commandToken            :: Token
  , commandCreateAt         :: UTCTime
  , commandUpdateAt         :: UTCTime
  , commandDeleteAt         :: UTCTime
  , commandCreatorId        :: UserId
  , commandTeamId           :: TeamId
  , commandTrigger          :: Text
  , commandMethod           :: Text
  , commandUsername         :: Text
  , commandIconURL          :: Text
  , commandAutoComplete     :: Bool
  , commandAutoCompleteDesc :: Text
  , commandAutoCompleteHint :: Text
  , commandDisplayName      :: Text
  , commandDescription      :: Text
  , commandURL              :: Text
  } deriving (Read, Show, Eq)

newtype CommandId = CmdI { unCmdI :: Id }
  deriving (Read, Show, Eq, Ord, Hashable, ToJSON, ToJSONKey, FromJSONKey, FromJSON)

instance IsId CommandId where
  toId   = unCmdI
  fromId = CmdI

instance HasId Command CommandId where
  getId = commandId

instance PrintfArg CommandId where
  formatArg = formatArg . idString

data CommandResponseType
  = CommandResponseInChannel
  | CommandResponseEphemeral
    deriving (Read, Show, Eq)

instance A.FromJSON CommandResponseType where
  parseJSON (A.String "in_channel") = return CommandResponseInChannel
  parseJSON (A.String "ephemeral")  = return CommandResponseEphemeral
  parseJSON _ = fail "Unknown command response type: expected `in_channel` or `ephemeral`"

data CommandResponse
  = CommandResponse
  { commandResponseType         :: Maybe CommandResponseType
  , commandResponseText         :: Text
  , commandResponseUsername     :: Text
  , commandResponseIconURL      :: Text
  , commandResponseGotoLocation :: Text
  , commandResponseAttachments  :: Seq PostPropAttachment
  } deriving (Read, Show, Eq)

instance A.FromJSON CommandResponse where
  parseJSON = A.withObject "CommandResponse" $ \o -> do
    commandResponseType         <- optional (o .: "response_type")
    commandResponseText         <- o .: "text"
    commandResponseUsername     <- o .: "username"
    commandResponseIconURL      <- o .: "icon_url"
    commandResponseGotoLocation <- o .: "goto_location"
    commandResponseAttachments  <- o .:? "attachments" .!= S.empty
    return CommandResponse { .. }

--

data UsersCreate
  = UsersCreate
  { usersCreateEmail          :: Text
  , usersCreatePassword       :: Text
  , usersCreateUsername       :: Text
  , usersCreateAllowMarketing :: Bool
  } deriving (Read, Show, Eq)

instance A.ToJSON UsersCreate where
  toJSON UsersCreate { .. } = A.object
    [ "email"           .= usersCreateEmail
    , "allow_marketing" .= usersCreateAllowMarketing
    , "password"        .= usersCreatePassword
    , "username"        .= usersCreateUsername
    ]

--

data TeamsCreate
  = TeamsCreate
  { teamsCreateDisplayName :: Text
  , teamsCreateName        :: Text
  , teamsCreateType        :: Type
  } deriving (Read, Show, Eq)

instance A.ToJSON TeamsCreate where
  toJSON TeamsCreate { .. } = A.object
    [ "display_name" .= teamsCreateDisplayName
    , "name"         .= teamsCreateName
    , "type"         .= teamsCreateType
    ]

--

data Reaction
  = Reaction
  { reactionUserId    :: UserId
  , reactionPostId    :: PostId
  , reactionEmojiName :: Text
  , reactionCreateAt  :: UTCTime
  } deriving (Read, Show, Eq)

instance A.FromJSON Reaction where
  parseJSON = A.withObject "Reaction" $ \v -> do
    reactionUserId    <- v .: "user_id"
    reactionPostId    <- v .: "post_id"
    reactionEmojiName <- v .: "emoji_name"
    reactionCreateAt  <- millisecondsToUTCTime <$> v .: "create_at"
    return Reaction { .. }

instance A.ToJSON Reaction where
  toJSON Reaction {.. } = A.object
    [ "user_id"    .= reactionUserId
    , "post_id"    .= reactionPostId
    , "emoji_name" .= reactionEmojiName
    , "create_at"  .= utcTimeToMilliseconds reactionCreateAt
    ]

-- * Preferences

data PreferenceCategory
  = PreferenceCategoryDirectChannelShow
  | PreferenceCategoryGroupChannelShow
  | PreferenceCategoryTutorialStep
  | PreferenceCategoryAdvancedSettings
  | PreferenceCategoryFlaggedPost
  | PreferenceCategoryDisplaySettings
  | PreferenceCategoryTheme
  | PreferenceCategoryAuthorizedOAuthApp
  | PreferenceCategoryNotifications
  | PreferenceCategoryLast
  | PreferenceCategoryOther Text
    deriving (Read, Show, Eq)

instance A.FromJSON PreferenceCategory where
  parseJSON = A.withText "PreferenceCategory" $ \t -> return $ case t of
    "direct_channel_show" -> PreferenceCategoryDirectChannelShow
    "group_channel_show"  -> PreferenceCategoryGroupChannelShow
    "tutorial_step"       -> PreferenceCategoryTutorialStep
    "advanced_settings"   -> PreferenceCategoryAdvancedSettings
    "flagged_post"        -> PreferenceCategoryFlaggedPost
    "display_settings"    -> PreferenceCategoryDisplaySettings
    "theme"               -> PreferenceCategoryTheme
    "oauth_app"           -> PreferenceCategoryAuthorizedOAuthApp
    "notifications"       -> PreferenceCategoryNotifications
    "last"                -> PreferenceCategoryLast
    _                     -> PreferenceCategoryOther t

instance A.ToJSON PreferenceCategory where
  toJSON cat = A.String $ case cat of
    PreferenceCategoryDirectChannelShow  -> "direct_channel_show"
    PreferenceCategoryGroupChannelShow   -> "group_channel_show"
    PreferenceCategoryTutorialStep       -> "tutorial_step"
    PreferenceCategoryAdvancedSettings   -> "advanced_settings"
    PreferenceCategoryFlaggedPost        -> "flagged_post"
    PreferenceCategoryDisplaySettings    -> "display_settings"
    PreferenceCategoryTheme              -> "theme"
    PreferenceCategoryAuthorizedOAuthApp -> "oauth_app"
    PreferenceCategoryNotifications      -> "notifications"
    PreferenceCategoryLast               -> "last"
    PreferenceCategoryOther t            -> t

data PreferenceName
  = PreferenceName { fromRawPreferenceName :: Text }
    deriving (Read, Show, Eq)

instance A.FromJSON PreferenceName where
  parseJSON = A.withText "PreferenceValue" (return . PreferenceName)

instance A.ToJSON PreferenceName where
  toJSON = A.toJSON . fromRawPreferenceName

data PreferenceValue
  = PreferenceValue { fromRawPreferenceValue :: Text }
    deriving (Read, Show, Eq)

instance A.FromJSON PreferenceValue where
  parseJSON = A.withText "PreferenceValue" (return . PreferenceValue)

instance A.ToJSON PreferenceValue where
  toJSON = A.toJSON . fromRawPreferenceValue

data Preference
  = Preference
  { preferenceUserId   :: UserId
  , preferenceCategory :: PreferenceCategory
  , preferenceName     :: PreferenceName
  , preferenceValue    :: PreferenceValue
  } deriving (Read, Show, Eq)

instance A.FromJSON Preference where
  parseJSON = A.withObject "Preference" $ \v -> do
    preferenceUserId   <- v .: "user_id"
    preferenceCategory <- v .: "category"
    preferenceName     <- v .: "name"
    preferenceValue    <- v .: "value"
    return Preference { .. }

instance A.ToJSON Preference where
  toJSON Preference { .. } = A.object
    [ "user_id"  .= preferenceUserId
    , "category" .= preferenceCategory
    , "name"     .= preferenceName
    , "value"    .= preferenceValue
    ]

data GroupChannelPreference =
    GroupChannelPreference { groupChannelId :: ChannelId
                           , groupChannelShow :: Bool
                           } deriving (Read, Show, Eq)

-- | Attempt to expose a 'Preference' as a 'FlaggedPost'
preferenceToGroupChannelPreference :: Preference -> Maybe GroupChannelPreference
preferenceToGroupChannelPreference
  Preference
    { preferenceCategory = PreferenceCategoryGroupChannelShow
    , preferenceName     = PreferenceName name
    , preferenceValue    = PreferenceValue value
    } = Just GroupChannelPreference
          { groupChannelId = CI (Id name)
          , groupChannelShow = value == "true"
          }
preferenceToGroupChannelPreference _ = Nothing

data FlaggedPost = FlaggedPost
  { flaggedPostUserId :: UserId
  , flaggedPostId     :: PostId
  , flaggedPostStatus :: Bool
  } deriving (Read, Show, Eq)

-- | Attempt to expose a 'Preference' as a 'FlaggedPost'
preferenceToFlaggedPost :: Preference -> Maybe FlaggedPost
preferenceToFlaggedPost
  Preference
    { preferenceCategory = PreferenceCategoryFlaggedPost
    , preferenceName     = PreferenceName name
    , preferenceValue    = PreferenceValue value
    , preferenceUserId   = userId
    } = Just FlaggedPost
          { flaggedPostUserId = userId
          , flaggedPostId     = PI (Id name)
          , flaggedPostStatus = value == "true"
          }
preferenceToFlaggedPost _ = Nothing

instance A.ToJSON FlaggedPost where
  toJSON FlaggedPost
    { flaggedPostUserId = userId
    , flaggedPostId     = PI (Id name)
    , flaggedPostStatus = status
    } = A.toJSON $ Preference
          { preferenceCategory = PreferenceCategoryFlaggedPost
          , preferenceName     = PreferenceName name
          , preferenceValue    = PreferenceValue (if status then "true" else "false")
          , preferenceUserId   = userId
          }

--

newtype HookId = HI { unHI :: Id }
  deriving (Read, Show, Eq, Ord, Hashable, ToJSON, ToJSONKey, FromJSONKey, FromJSON)

instance IsId HookId where
  toId   = unHI
  fromId = HI

instance PrintfArg HookId where
  formatArg = formatArg . idString

--

newtype InviteId = II { unII :: Id }
  deriving (Read, Show, Eq, Ord, Hashable, ToJSON, ToJSONKey, FromJSONKey, FromJSON)

instance IsId InviteId where
  toId   = unII
  fromId = II

instance PrintfArg InviteId where
  formatArg = formatArg . idString

--

newtype TokenId = TkI { unTkI :: Id }
  deriving (Read, Show, Eq, Ord, Hashable, ToJSON, ToJSONKey, FromJSONKey, FromJSON)

instance IsId TokenId where
  toId   = unTkI
  fromId = TkI

instance PrintfArg TokenId where
  formatArg = formatArg . idString

--

newtype AppId = AI { unAI :: Id }
  deriving (Read, Show, Eq, Ord, Hashable, ToJSON, ToJSONKey, FromJSONKey, FromJSON)

instance IsId AppId where
  toId   = unAI
  fromId = AI

instance PrintfArg AppId where
  formatArg = formatArg . idString

--

newtype JobId = JI { unJI :: Id }
  deriving (Read, Show, Eq, Ord, Hashable, ToJSON, ToJSONKey, FromJSONKey, FromJSON)

instance IsId JobId where
  toId   = unJI
  fromId = JI

instance PrintfArg JobId where
  formatArg = formatArg . idString

--

newtype EmojiId = EI { unEI :: Id }
  deriving (Read, Show, Eq, Ord, Hashable, ToJSON, ToJSONKey, FromJSONKey, FromJSON)

instance IsId EmojiId where
  toId   = unEI
  fromId = EI

instance PrintfArg EmojiId where
  formatArg = formatArg . idString

--

newtype ReportId = RI { unRI :: Id }
  deriving (Read, Show, Eq, Ord, Hashable, ToJSON, ToJSONKey, FromJSONKey, FromJSON)

instance IsId ReportId where
  toId   = unRI
  fromId = RI

instance PrintfArg ReportId where
  formatArg = formatArg . idString

-- FIXMES

instance A.ToJSON User where toJSON = undefined
instance A.ToJSON TeamMember where toJSON = undefined
instance A.ToJSON Team where toJSON = undefined
instance A.FromJSON Command where parseJSON = undefined
instance A.ToJSON Command where toJSON = undefined
