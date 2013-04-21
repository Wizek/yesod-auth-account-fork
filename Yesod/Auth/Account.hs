{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

-- | An auth plugin for accounts. Each account consists of a username, email, and password.
--
-- This module is designed so that you can use the default pages for login, account
-- creation, change password, etc.  But the module also exports some forms which you
-- can embed into your own pages, customizing the account process.  The minimal requirements
-- to use this module are:
--
-- * If you are not using persistent or just want more control over the user data, you can use
--   any datatype for user information and make it an instance of 'UserCredentials'.  You must
--   also create an instance of 'AccountDB'.
--
-- * You may use a user datatype created by persistent, in which case you can make the datatype
--   an instance of 'PersistUserCredentials' instead of 'UserCredentials'.  In this case, 
--   'AccountPersistDB' from this module already implements the 'AccountDB' interface for you.
--
-- * Make your master site an instance of 'AccountSendEmail'.  By default, this class
--   just logs a message so during development this class requires no implementation.
--
-- * Make your master site and database an instance of 'YesodAuthAccount'.  There is only
--   one required function which must be implemented ('runAccountDatabase') although there
--   are several functions you can override in this class to customize the behavior of this
--   module.
--
-- * Include 'accountPlugin' in the list of plugins in your instance of 'YesodAuth'.
module Yesod.Auth.Account(
    -- * Plugin
      Username
    , newAccountR
    , resetPasswordR
    , accountPlugin
    
    -- * Login
    , LoginData(..)
    , loginForm
    , loginFormPostTargetR
    , loginWidget

    -- * New Account
    -- $newaccount
    , verifyR
    , NewAccountData(..)
    , newAccountForm
    , newAccountWidget
    , createNewAccount
    , resendVerifyEmailForm
    , resendVerifyR
    , resendVerifyEmailWidget

    -- * Password Reset
    -- $passwordreset
    , newPasswordR
    , resetPasswordForm
    , resetPasswordWidget
    , NewPasswordData(..)
    , newPasswordForm
    , setPasswordR
    , newPasswordWidget

    -- * Database and Email
    , UserCredentials(..)
    , PersistUserCredentials(..)
    , AccountDB(..)
    , AccountSendEmail(..)

    -- * Persistent
    , AccountPersistDB
    , runAccountPersistDB

    -- * Customization
    , YesodAuthAccount(..)

    -- * Helpers
    , hashPassword
    , verifyPassword
    , newVerifyKey
) where

import Control.Applicative
import Control.Monad.Reader hiding (lift)
import qualified Crypto.PasswordStore as PS
import qualified Data.ByteString as B
import qualified Data.ByteString.Base64.URL as B64
import Data.Char (isAlphaNum)
import qualified Data.Text as T
import qualified Data.Text.Encoding as TE
import qualified Database.Persist as P
import qualified Database.Persist.Query.Internal as P (Update)
import System.Random (newStdGen, randoms)
import Yesod hiding (get, replace, insertKey, Entity, entityVal)
import Yesod.Auth
import qualified Yesod.Auth.Message as Msg

-- | Each user is uniquely identified by a username.
type Username = T.Text

-- | The account authentication plugin.  Here is a complete example using persistent.
--
-- >{-# LANGUAGE QuasiQuotes, TypeFamilies, GeneralizedNewtypeDeriving #-}
-- >{-# LANGUAGE FlexibleContexts, FlexibleInstances, TemplateHaskell, OverloadedStrings #-}
-- >{-# LANGUAGE GADTs, MultiParamTypeClasses, TypeSynonymInstances #-}
-- >
-- >import Data.Text (Text)
-- >import Data.ByteString (ByteString)
-- >import Database.Persist.Sqlite
-- >import Control.Monad.Logger (runStderrLoggingT)
-- >import Yesod
-- >import Yesod.Auth
-- >import Yesod.Auth.Account
-- >
-- >share [mkPersist sqlSettings, mkMigrate "migrateAll"] [persistUpperCase|
-- >User
-- >    username Text
-- >    UniqueUsername username
-- >    password ByteString
-- >    emailAddress Text
-- >    verified Bool
-- >    verifyKey Text
-- >    resetPasswordKey Text
-- >    deriving Show
-- >|]
-- >
-- >instance PersistUserCredentials User where
-- >    userUsernameF = UserUsername
-- >    userPasswordHashF = UserPassword
-- >    userEmailF = UserEmailAddress
-- >    userEmailVerifiedF = UserVerified
-- >    userEmailVerifyKeyF = UserVerifyKey
-- >    userResetPwdKeyF = UserResetPasswordKey
-- >    uniqueUsername = UniqueUsername
-- >
-- >    userCreate name email key pwd = User name pwd email False key ""
-- >
-- >data MyApp = MyApp ConnectionPool
-- >
-- >mkYesod "MyApp" [parseRoutes|
-- >/ HomeR GET
-- >/auth AuthR Auth getAuth
-- >|]
-- >
-- >instance Yesod MyApp
-- >
-- >instance RenderMessage MyApp FormMessage where
-- >    renderMessage _ _ = defaultFormMessage
-- >
-- >instance YesodPersist MyApp where
-- >    type YesodPersistBackend MyApp = SqlPersist
-- >    runDB action = do
-- >        MyApp pool <- getYesod
-- >        runSqlPool action pool
-- >
-- >instance YesodAuth MyApp where
-- >    type AuthId MyApp = Username
-- >    getAuthId = return . Just . credsIdent
-- >    loginDest _ = HomeR
-- >    logoutDest _ = HomeR
-- >    authPlugins _ = [accountPlugin]
-- >    authHttpManager _ = error "No manager needed"
-- >    onLogin = return ()
-- >
-- >instance AccountSendEmail MyApp
-- >
-- >instance YesodAuthAccount (AccountPersistDB MyApp User) MyApp where
-- >    runAccountDB = runAccountPersistDB
-- >
-- >getHomeR :: Handler RepHtml
-- >getHomeR = do
-- >    maid <- maybeAuthId
-- >    case maid of
-- >        Nothing -> defaultLayout $ [whamlet|
-- ><p>Please visit the <a href="@{AuthR LoginR}">Login page</a>
-- >|]
-- >        Just u -> defaultLayout $ [whamlet|
-- ><p>You are logged in as #{u}
-- ><p><a href="@{AuthR LogoutR}">Logout</a>
-- >|]
-- >
-- >main :: IO ()
-- >main = withSqlitePool "test.db3" 10 $ \pool -> do
-- >    runStderrLoggingT $ runSqlPool (runMigration migrateAll) pool
-- >    warpDebug 3000 $ MyApp pool
--
accountPlugin :: YesodAuthAccount db master => AuthPlugin master
accountPlugin = AuthPlugin "account" dispatch loginWidget
    where dispatch "POST" ["login"] = postLoginR >>= sendResponse
          dispatch "GET"  ["newaccount"] = getNewAccountR >>= sendResponse
          dispatch "POST" ["newaccount"] = postNewAccountR >>= sendResponse
          dispatch "GET"  ["resetpassword"] = getResetPasswordR >>= sendResponse
          dispatch "POST" ["resetpassword"] = postResetPasswordR >>= sendResponse
          dispatch "GET"  ["verify", u, k] = getVerifyR u k >>= sendResponse
          dispatch "GET"  ["newpassword", u, k] = getNewPasswordR u k >>= sendResponse
          dispatch "POST" ["setpassword"] = postSetPasswordR >>= sendResponse
          dispatch "POST" ["resendverifyemail"] = postResendVerifyEmailR >>= sendResponse
          dispatch _ _ = notFound

-- | The POST target for the 'loginForm'.
loginFormPostTargetR :: AuthRoute
loginFormPostTargetR = PluginR "account" ["login"]

-- | Route for the default new account page.
--
-- See the New Account section below for customizing the new account process.
newAccountR :: AuthRoute
newAccountR = PluginR "account" ["newaccount"]

-- | Route for the reset password page.
--
-- This page allows the user to reset their password by requesting an email with a
-- reset URL be sent to them.  See the Password Reset section below for customization.
resetPasswordR :: AuthRoute
resetPasswordR = PluginR "account" ["resetpassword"]

-- | The URL sent in an email for email verification
verifyR :: Username 
        -> T.Text -- ^ The verification key
        -> AuthRoute
verifyR u k = PluginR "account" ["verify", u, k]

-- | The POST target for resending a verification email
resendVerifyR :: AuthRoute
resendVerifyR = PluginR "account" ["resendverifyemail"]

-- | The URL sent in an email when the user requests to reset their password
newPasswordR :: Username
             -> T.Text -- ^ The verification key
             -> AuthRoute
newPasswordR u k = PluginR "account" ["newpassword", u, k]

-- | The POST target for reseting the password
setPasswordR :: AuthRoute
setPasswordR = PluginR "account" ["setpassword"]

-- | TODO: move these into Yesod.Auth.Message
data AccountMsg = MsgUsername
                | MsgForgotPassword
                | MsgInvalidUsername
                | MsgInvalidUserOrPwd
                | MsgUsernameExists T.Text
                | MsgResendVerifyEmail
                | MsgResetPwdTitle
                | MsgSendResetPwdEmail
                | MsgResetPwdEmailSent
                | MsgEmailVerified
                | MsgEmailUnverified

instance RenderMessage m AccountMsg where
    renderMessage _ _ MsgUsername = "Username"
    renderMessage _ _ MsgForgotPassword = "Forgot password?"
    renderMessage _ _ MsgInvalidUsername = "Invalid username"
    renderMessage _ _ MsgInvalidUserOrPwd = "Invalid username or password"
    renderMessage _ _ (MsgUsernameExists u) =
        T.concat ["The username ", u, " already exists.  Please choose an alternate username."]
    renderMessage _ _ MsgResendVerifyEmail = "Resend verification email"
    renderMessage _ _ MsgResetPwdTitle = "Reset your password"
    renderMessage _ _ MsgSendResetPwdEmail = "Send email to reset password"
    renderMessage _ _ MsgResetPwdEmailSent = "A password reset email has been sent to your email address."
    renderMessage _ _ MsgEmailVerified = "Your email has been verified."
    renderMessage _ _ MsgEmailUnverified = "Your email has not yet been verified."


---------------------------------------------------------------------------------------------------

-- | The data collected in the login form.
data LoginData = LoginData {
      loginUsername :: T.Text
    , loginPassword :: T.Text
} deriving Show

-- | The login form.
--
-- You can embed this form into your own pages if you want a custom rendering of this
-- form or to include a login form on your own pages. The form submission should be
-- posted to 'loginFormPostTargetR'.
loginForm :: YesodAuthAccount db master => AForm s master LoginData
loginForm = LoginData <$> areq (checkM checkValidUsername textField) userSettings Nothing
                      <*> areq passwordField pwdSettings Nothing
    where userSettings = FieldSettings (SomeMessage MsgUsername) Nothing (Just "username") Nothing []
          pwdSettings  = FieldSettings (SomeMessage Msg.Password) Nothing (Just "password") Nothing []

-- | A default rendering of 'loginForm' using renderDivs.
--
-- This is the widget used in the default implementation of 'loginHandler'.
-- The widget also includes links to the new account and reset password pages.
loginWidget :: YesodAuthAccount db master => (Route Auth -> Route master) -> GWidget s master ()
loginWidget tm = do
    ((_,widget), enctype) <- lift $ runFormPostNoToken $ renderDivs loginForm
    [whamlet|
<div .loginDiv>
    <form method=post enctype=#{enctype} action=@{tm loginFormPostTargetR}>
        ^{widget}
        <input type=submit value=_{Msg.LoginTitle}>
    <p>
        <a href="@{tm newAccountR}">_{Msg.RegisterLong}
        <a href="@{tm resetPasswordR}">_{MsgForgotPassword}
|]

postLoginR :: YesodAuthAccount db master => GHandler Auth master RepHtml
postLoginR = do
    ((result, _), _) <- runFormPostNoToken $ renderDivs loginForm
    mr <- getMessageRender
    muser <- case result of
                FormMissing -> invalidArgs ["Form is missing"]
                FormFailure msg -> return $ Left msg
                FormSuccess (LoginData uname pwd) -> do
                    mu <- runAccountDB $ loadUser uname
                    case mu of
                        Nothing -> return $ Left [mr MsgInvalidUserOrPwd]
                        Just u -> return $
                            if verifyPassword pwd (userPasswordHash u)
                                then Right u
                                else Left [mr MsgInvalidUserOrPwd]
    
    tm <- getRouteToMaster
    case muser of
        Left errs -> do
            setMessage $ toHtml $ T.concat errs
            redirect $ tm LoginR

        Right u -> if userEmailVerified u
                        then do setCreds True $ Creds "account" (username u) []
                                -- setCreds should redirect so we will never get here
                                badMethod
                        else unregisteredLogin u

---------------------------------------------------------------------------------------------------

-- $newaccount
-- The new account process works as follows.
--
-- * A GET to 'newAccountR' displays a form requesting account information
--   from the user.  The specific page to display can be customized by implementing
--   'getNewAccountR'.  By default, this is the content of 'newAccountForm' which
--   consists of an username, email, and a password.  The target for the form is a
--   POST to 'newAccountR'.
--
-- * A POST to 'newAccountR' handles the account creation.  By default, 'postNewAccountR'
--   processes 'newAccountForm' and then calls 'createNewAccount' to create the account
--   in the database, generate a random key, and send an email with the verification key.
--   If you have modified 'getNewAccountR' to add additional fields to the new account
--   form (for example CAPTCHA or other account info), you can override 'postNewAccountR'
--   to handle the form.  You should still call 'createNewAccount' from your own processing
--   function.
--
-- * The verification email includes a URL to 'verifyR'.  A GET to 'verifyR' checks
--   if the key matches, and if so updates the database and uses 'setCreds' to log the
--   user in and redirects to 'loginDest'.  If an error occurs, a message is set and the
--   user is redirected to 'LoginR'.
--
-- * A POST to 'resendVerifyR' of 'resendVerifyEmailForm' will generate a new verification key
--   and resend the email.  By default, 'unregisteredLogin' displays the form for resending
--   the eamil.

-- | The data collected in the new account form.
data NewAccountData = NewAccountData {
      newAccountUsername :: Username
    , newAccountEmail :: T.Text
    , newAccountPassword1 :: T.Text
    , newAccountPassword2 :: T.Text
} deriving Show

-- | The new account form.
--
-- You can embed this form into your own pages or into 'getNewAccountR'.  The form
-- submission should be posted to 'newAccountR'.  Alternatively, you could embed this
-- form into a larger form where you prompt for more information during account
-- creation.  In this case, the NewAccountData should be passed to 'createNewAccount'
-- from inside 'postNewAccountR'.
newAccountForm :: (YesodAuth m, RenderMessage m FormMessage) => AForm s m NewAccountData
newAccountForm = NewAccountData <$> areq textField userSettings Nothing
                                <*> areq emailField emailSettings Nothing
                                <*> areq passwordField pwdSettings1 Nothing
                                <*> areq passwordField pwdSettings2 Nothing
    where userSettings  = FieldSettings (SomeMessage MsgUsername) Nothing Nothing Nothing []
          emailSettings = FieldSettings (SomeMessage Msg.Email) Nothing Nothing Nothing []
          pwdSettings1  = FieldSettings (SomeMessage Msg.Password) Nothing Nothing Nothing []
          pwdSettings2  = FieldSettings (SomeMessage Msg.ConfirmPass) Nothing Nothing Nothing []

-- | A default rendering of the 'newAccountForm' using renderDivs.
newAccountWidget :: (YesodAuth m, RenderMessage m FormMessage) => (Route Auth -> Route m) -> GWidget s m ()
newAccountWidget tm = do
    ((_,widget), enctype) <- lift $ runFormPost $ renderDivs newAccountForm
    [whamlet|
<div .newaccountDiv>
    <form method=post enctype=#{enctype} action=@{tm newAccountR}>
        ^{widget}
        <input type=submit value=_{Msg.Register}>
|]

-- | An action to create a new account.
--
-- You can use this action inside your own implementation of 'postNewAccountR' if you
-- add additional fields to the new account creation.  This action assumes the user has
-- not yet been created in the database and will create the user, so this action should
-- be run first in your handler.  Note that this action does not check if the passwords
-- are equal. If an error occurs (username exists, etc.) this will set a message and
-- redirect to 'newAccountR'.
createNewAccount :: YesodAuthAccount db master => NewAccountData -> (Route Auth -> Route master) -> GHandler s master (UserAccount db)
createNewAccount (NewAccountData u email pwd _) tm = do
    muser <- runAccountDB $ loadUser u
    case muser of
        Just _ -> do setMessageI $ MsgUsernameExists u
                     redirect $ tm newAccountR
        Nothing -> return ()

    key <- newVerifyKey
    hashed <- hashPassword pwd

    mnew <- runAccountDB $ addNewUser u email key hashed
    new <- case mnew of
        Left err -> do setMessage $ toHtml err
                       redirect $ tm newAccountR
        Right x -> return x

    render <- getUrlRender
    sendVerifyEmail u email $ render $ tm $ verifyR u key
    setMessageI $ Msg.ConfirmationEmailSent email
    return new

getVerifyR :: YesodAuthAccount db master => Username -> T.Text -> GHandler Auth master ()
getVerifyR uname k = do
    tm <- getRouteToMaster
    muser <- runAccountDB $ loadUser uname
    case muser of
        Nothing -> do setMessageI Msg.InvalidKey
                      redirect $ tm LoginR
        Just user -> do when (    userEmailVerifyKey user == "" 
                               || userEmailVerifyKey user /= k
                               || userEmailVerified user
                             ) $ do
                            setMessageI Msg.InvalidKey
                            redirect $ tm LoginR
                        runAccountDB $ verifyAccount user
                        setMessageI MsgEmailVerified
                        setCreds True $ Creds "account" uname []

-- | A form to allow the user to request the email validation be resent.
--
-- Intended for use in 'unregisteredLogin'.  The result should be posted to
-- 'resendVerifyR'.
resendVerifyEmailForm :: RenderMessage m FormMessage => Username -> AForm s m Username
resendVerifyEmailForm u = areq hiddenField "" $ Just u

-- | A default rendering of 'resendVerifyEmailForm'
resendVerifyEmailWidget :: RenderMessage m FormMessage => Username -> (Route Auth -> Route m) -> GWidget s m ()
resendVerifyEmailWidget u tm = do
    ((_,widget), enctype) <- lift $ runFormPost $ renderDivs $ resendVerifyEmailForm u
    [whamlet|
<div .resendVerifyEmailDiv>
    <form method=post enctype=#{enctype} action=@{tm resendVerifyR}>
        ^{widget}
        <input type=submit value=_{MsgResendVerifyEmail}>
|]

postResendVerifyEmailR :: YesodAuthAccount db master => GHandler Auth master ()
postResendVerifyEmailR = do
    ((result, _), _) <- runFormPost $ renderDivs $ resendVerifyEmailForm ""
    muser <- case result of
                FormMissing -> invalidArgs ["Form is missing"]
                FormFailure msg -> invalidArgs msg
                FormSuccess uname -> runAccountDB $ loadUser uname

    case muser of
        -- The username is a hidden field so it should be correct.  No need to set a message or redirect.
        Nothing -> invalidArgs ["Invalid username"] 
        Just u  -> do
            key <- newVerifyKey
            tm <- getRouteToMaster
            runAccountDB $ setVerifyKey u key
            render <- getUrlRender
            sendVerifyEmail (username u) (userEmail u) $ render $ tm $ verifyR (username u) key
            setMessageI $ Msg.ConfirmationEmailSent (userEmail u)
            redirect $ tm LoginR

---------------------------------------------------------------------------------------------------

-- $passwordreset
-- This plugin implements password reset by sending the user an email containing a URL.  When
-- the user visits this URL, they are prompted for a new password.  This works as follows:
--
-- * A GET to 'resetPasswordR' displays a form prompting for username, which when submitted sends
--   a post to 'resetPasswordR'.   You can customize this page by overriding 'getResetPasswordR'
--   or by embedding 'resetPasswordForm' into your own page and not linking your users to this URL.
--
-- * A POST to 'resetPasswordR' of 'resetPasswordForm' creates a new key, stores it in the database,
--   and sends an email.  It then sets a message and redirects to the login page.  You can redirect
--   somewhere else (or carry out other actions) at the end of 'sendNewPasswordEmail'.  The URL sent
--   in the email is 'setPasswordR'.
--
-- * A GET to 'newPasswordR' checks if the key in the URL is correct and if so displays a form
--   where the user can set a new password.  The key is set as a hidden field in this form.  You
--   can customize the look of this page by overriding 'setPasswordHandler'.
--
-- * A POST to 'setPasswordR' of 'setPasswordForm' checks if the key is correct and if so,
--   resets the password.  It then calls 'setCreds' to successfully log in and so redirects to
--   'loginDest'.
--
-- * You can set 'allowPasswordReset' to False, in which case the relevant routes in this
--   plugin return 404.  You can then implement password reset yourself.

-- | A form for the user to request that an email be sent to them to allow them to reset
-- their password.  This form contains a field for the username (plus the CSRF token).
-- The form should be posted to 'resetPasswordR'.
resetPasswordForm :: RenderMessage m FormMessage => AForm s m Username
resetPasswordForm = areq textField userSettings Nothing
    where userSettings = FieldSettings (SomeMessage MsgUsername) Nothing (Just "username") Nothing []

-- | A default rendering of 'resetPasswordForm'.
resetPasswordWidget :: RenderMessage m FormMessage => (Route Auth -> Route m) -> GWidget s m ()
resetPasswordWidget tm = do
    ((_,widget), enctype) <- lift $ runFormPost $ renderDivs resetPasswordForm
    [whamlet|
<div .resetPasswordDiv>
    <form method=post enctype=#{enctype} action=@{tm resetPasswordR}>
        ^{widget}
        <input type=submit value=_{MsgSendResetPwdEmail}>
|]

postResetPasswordR :: YesodAuthAccount db master => GHandler Auth master RepHtml
postResetPasswordR = do
    allow <- allowPasswordReset <$> getYesod
    unless allow notFound
    tm <- getRouteToMaster
    ((result, _), _) <- runFormPost $ renderDivs resetPasswordForm
    mdata <- case result of
                FormMissing -> invalidArgs ["Form is missing"]
                FormFailure msg -> return $ Left msg
                FormSuccess uname -> Right <$> runAccountDB (loadUser uname)

    case mdata of
        Left errs -> do
            setMessage $ toHtml $ T.concat errs
            redirect $ tm LoginR

        Right Nothing -> do
            setMessageI MsgInvalidUsername
            redirect $ tm resetPasswordR

        Right (Just u) -> do key <- newVerifyKey
                             runAccountDB $ setNewPasswordKey u key
                             render <- getUrlRender
                             sendNewPasswordEmail (username u) (userEmail u) $ render $ tm $ newPasswordR (username u) key
                             -- Don't display the email in the message since anybody can request the resend.
                             setMessageI MsgResetPwdEmailSent
                             redirect $ tm LoginR

-- | The data for setting a new password.
data NewPasswordData = NewPasswordData {
      newPasswordUser :: Username
    , newPasswordKey  :: T.Text
    , newPasswordPwd1 :: T.Text
    , newPasswordPwd2 :: T.Text
} deriving Show

-- | The form for setting a new password. It contains hidden fields for the username and key and prompts
-- for the passwords.  This form should be posted to 'setPasswordR'.
newPasswordForm :: (YesodAuth m, RenderMessage m FormMessage)
                => Username 
                -> T.Text -- ^ key
                -> AForm s m NewPasswordData
newPasswordForm u k = NewPasswordData <$> areq hiddenField "" (Just u)
                                      <*> areq hiddenField "" (Just k)
                                      <*> areq passwordField pwdSettings1 Nothing
                                      <*> areq passwordField pwdSettings2 Nothing
    where pwdSettings1 = FieldSettings (SomeMessage Msg.NewPass) Nothing Nothing Nothing []
          pwdSettings2 = FieldSettings (SomeMessage Msg.ConfirmPass) Nothing Nothing Nothing []

-- | A default rendering of 'newPasswordForm'.
newPasswordWidget :: YesodAuthAccount db master => UserAccount db -> (Route Auth -> Route master) -> GWidget s master ()
newPasswordWidget user tm = do
    let key = userResetPwdKey user
    ((_,widget), enctype) <- lift $ runFormPost $ renderDivs (newPasswordForm (username user) key)
    [whamlet|
<div .newpassDiv>
    <p>_{Msg.SetPass}
    <form method=post enctype=#{enctype} action=@{tm setPasswordR}>
        ^{widget}
        <input type=submit value=_{Msg.SetPassTitle}>
|]

getNewPasswordR :: YesodAuthAccount db master => Username -> T.Text -> GHandler Auth master RepHtml
getNewPasswordR uname k = do
    allow <- allowPasswordReset <$> getYesod
    unless allow notFound
    muser <- runAccountDB $ loadUser uname
    tm <- getRouteToMaster
    case muser of
        Just user | userResetPwdKey user /= "" && userResetPwdKey user == k ->
            setPasswordHandler user

        _ -> do setMessageI Msg.InvalidKey
                redirect $ tm LoginR

postSetPasswordR :: YesodAuthAccount db master => GHandler Auth master ()
postSetPasswordR = do
    allow <- allowPasswordReset <$> getYesod
    unless allow notFound
    tm <- getRouteToMaster
    ((result,_), _) <- runFormPost $ renderDivs (newPasswordForm "" "")
    mnew <- case result of
                FormMissing -> invalidArgs ["Form is missing"]
                FormFailure msg -> return $ Left msg
                FormSuccess d | newPasswordPwd1 d == newPasswordPwd2 d -> return $ Right d
                FormSuccess d -> do setMessageI Msg.PassMismatch
                                    redirect $ tm $ newPasswordR (newPasswordUser d) (newPasswordKey d)

    case mnew of
        Left errs -> do
            setMessage $ toHtml $ T.concat errs
            redirect $ tm LoginR

        Right d -> do muser <- runAccountDB $ loadUser (newPasswordUser d)
                      case muser of
                        -- username is a hidden field so it should be correct.  No need to set a message and redirect.
                        Nothing -> permissionDenied "Invalid username"
                        Just user -> do
                              -- the key is a hidden field, no need to set a message and redirect.
                              when (userResetPwdKey user == "") $ permissionDenied "Invalid key"
                              when (newPasswordKey d /= userResetPwdKey user) $ permissionDenied "Invalid key"

                              hashed <- hashPassword (newPasswordPwd1 d)
                              runAccountDB $ setNewPassword user hashed
                              setMessageI Msg.PassUpdated
                              setCreds True $ Creds "account" (newPasswordUser d) []

---------------------------------------------------------------------------------------------------

-- | Interface for the data type which stores the user info when not using persistent.
--
--   You must make a data type that is either an instance of this class or of
--   'PersistUserCredentials', depending on if you are using persistent or not.
--
--   Users are uniquely identified by their username, and for each user we must store the email,
--   the verify status, a hashed user password, and a reset password key.  The format for the
--   hashed password is the format from "Crypto.PasswordStore".  If the email has been verified
--   and no password reset is in progress, the relevent keys should be the empty string.
class UserCredentials u where
    username           :: u -> Username
    userPasswordHash   :: u -> B.ByteString -- ^ see "Crypto.PasswordStore" for the format
    userEmail          :: u -> T.Text
    userEmailVerified  :: u -> Bool       -- ^ the status of the user's email verification
    userEmailVerifyKey :: u -> T.Text     -- ^ the verification key which is sent in an email.
    userResetPwdKey    :: u -> T.Text     -- ^ the reset password key which is sent in an email.

-- | Interface for the data type which stores the user info when using persistent.
--
--   You must make a data type that is either an instance of this class or of
--   'UserCredentials', depending on if you are using persistent or not.
class PersistUserCredentials u where
    userUsernameF       :: P.EntityField u Username
    userPasswordHashF   :: P.EntityField u B.ByteString
    userEmailF          :: P.EntityField u T.Text
    userEmailVerifiedF  :: P.EntityField u Bool
    userEmailVerifyKeyF :: P.EntityField u T.Text
    userResetPwdKeyF    :: P.EntityField u T.Text
#if 1
    uniqueUsername      :: T.Text -> P.Unique u
#else
    uniqueUsername      :: T.Text -> P.Unique u (P.PersistEntityBackend u)
#endif

    -- | Creates a new user for use during 'addNewUser'.  The starting reset password
    -- key should be the empty string.
    userCreate :: Username
               -> T.Text       -- ^ unverified email
               -> T.Text       -- ^ email verification key
               -> B.ByteString -- ^ hashed and salted password
               -> u

-- | These are the database operations to load and update user data.
--
-- Persistent users can use 'AccountPersistDB' and don't need to create their own instance.
-- If you are not using persistent or are using persistent but want to customize the database
-- activity, you must manually create an instance.  The kind of @b@ is @* -> * -> *@.  The first
-- type argument to @b@ is a subsite, and @b sub@ should be a monad which embeds
-- @GHandler sub master a@.  It is unfortunate that the order of sub and master must be flipped,
-- so you will need a newtype.  For example,
--
-- > newtype MyAccountDB sub a = MyAccountDB {runMyAccountDB :: GHandler sub MyApp a}
-- >    deriving (Monad, MonadIO)
-- > instance MonadLift (GHandler sub MyApp) (MyAccountDB sub) where
-- >     lift = MyAccountDB
-- > instance AccountDB MyAccountDB where
-- >     ....
--
class AccountDB b where
    -- | The data type which stores the user.  Must be an instance of 'UserCredentials'.
    type UserAccount b

    -- | Load a user by username
    loadUser :: Username -> b sub (Maybe (UserAccount b))

    -- | Create new account.  The password reset key should be added as an empty string.
    -- The creation can fail with an error message, in which case the error is set in a
    -- message and the post handler redirects to 'newAccountR'.
    addNewUser :: Username     -- ^ username
               -> T.Text       -- ^ unverified email
               -> T.Text       -- ^ the email verification key
               -> B.ByteString -- ^ hashed and salted password
               -> b sub (Either T.Text (UserAccount b))

    -- | Mark the account as successfully verified.  This should reset the email validation key
    -- to the empty string.
    verifyAccount :: UserAccount b -> b sub ()

    -- | Change/set the users email verification key.
    setVerifyKey :: UserAccount b 
                 -> T.Text -- ^ the verification key
                 -> b sub ()

    -- | Change/set the users password reset key.
    setNewPasswordKey :: UserAccount b
                      -> T.Text -- ^ the key
                      -> b sub ()

    -- | Set a new hashed password.  This should also set the password reset key to the empty
    -- string.
    setNewPassword :: UserAccount b
                   -> B.ByteString -- ^ hashed password
                   -> b sub ()

-- | A class to send email.
--
-- Both of the methods are implemented by default to just log a message,
-- so during development there are no required methods.
class AccountSendEmail master where
    sendVerifyEmail :: Username
                    -> T.Text -- ^ email address
                    -> T.Text -- ^ verification URL
                    -> GHandler s master ()
    sendVerifyEmail uname email url =
        $(logInfo) $ T.concat [ "Verification email for "
                              , uname
                              , " (", email, "): "
                              , url
                              ]

    sendNewPasswordEmail :: Username
                         -> T.Text -- ^ email address
                         -> T.Text -- ^ new password URL
                         -> GHandler s master ()
    sendNewPasswordEmail uname email url =
        $(logInfo) $ T.concat [ "Reset password email for "
                              , uname
                              , " (", email, "): "
                              , url
                              ]

-- | The main class controlling the account plugin.
--
-- You must make your database instance of 'AccountDB' and your master site
-- an instance of this class.  The only required method is 'runAccountDB', although
-- this class contains many other methods to customize the behavior of the account plugin.
--
-- Continuing the example from the manual creation of 'AccountDB', a minimal instance is
--
-- > instance YesodAuthAccount MyAccountDB MyApp where
-- >     runAccountDB = runMyAccountDB
--
-- If instead you are using persistent and have made an instance of 'PersistUserCredentials',
-- a minimal instance is
--
-- > instance YesodAuthAccount (AccountPersistDB MyApp User) MyApp where
-- >    runAccountDB = runPersistAccountDB
--
class (YesodAuth master
      , AccountSendEmail master
      , AccountDB db
      , UserCredentials (UserAccount db)
      , RenderMessage master FormMessage
      ) => YesodAuthAccount db master | master -> db where

    -- | Run a database action.  This is the only required method.
    runAccountDB :: db sub a -> GHandler sub master a

    -- | A form validator for valid usernames during new account creation.
    --
    -- By default this allows usernames made up of 'isAlphaNum'.  You can also ignore
    -- this validation and instead validate in 'addNewUser', but validating here
    -- allows the validation to occur before database activity (checking existing
    -- username) and before random salt creation (requires IO).
    checkValidUsername :: Username -> GHandler s master (Either T.Text Username)
    checkValidUsername u | T.all isAlphaNum u = return $ Right u
    checkValidUsername _ = do
        mr <- getMessageRender
        return $ Left $ mr MsgInvalidUsername

    -- | What to do when the user logs in and the email has not yet been verified.
    --              
    -- By default, this displays a message and contains 'resendVerifyEmailForm', allowing
    -- the user to resend the verification email.  The handler is run inside the post
    -- handler for login, so you can call 'setCreds' to preform a successful login.
    unregisteredLogin :: UserAccount db -> GHandler Auth master RepHtml
    unregisteredLogin u = do
        tm <- getRouteToMaster
        defaultLayout $ do
            setTitleI MsgEmailUnverified
            [whamlet|
<p>_{MsgEmailUnverified}
^{resendVerifyEmailWidget (username u) tm}
|]

    -- | The new account page.
    --
    -- This is the page which is displayed on a GET to 'newAccountR', and defaults to
    -- an embedding of 'newAccountWidget'.
    getNewAccountR :: GHandler Auth master RepHtml
    getNewAccountR = do
        tm <- getRouteToMaster
        defaultLayout $ do
            setTitleI Msg.RegisterLong
            newAccountWidget tm

    -- | Handles new account creation.
    --
    -- By default, this processes 'newAccountForm', calls 'createNewAccount', sets a message
    -- and redirects to LoginR.  If an error occurs, a message is set and the user is
    -- redirected to 'newAccountR'.
    postNewAccountR :: GHandler Auth master RepHtml
    postNewAccountR = do
        tm <- getRouteToMaster
        mr <- getMessageRender
        ((result, _), _) <- runFormPost $ renderDivs newAccountForm
        mdata <- case result of
                    FormMissing -> invalidArgs ["Form is missing"]
                    FormFailure msg -> return $ Left msg
                    FormSuccess d -> return $ if newAccountPassword1 d == newAccountPassword2 d
                                        then Right d
                                        else Left [mr Msg.PassMismatch]
        case mdata of
            Left errs -> do
                setMessage $ toHtml $ T.concat errs
                redirect $ tm newAccountR

            Right d -> do void $ createNewAccount d tm
                          redirect $ tm LoginR

    -- | Should the password reset inside this plugin be allowed?  Defaults to True
    allowPasswordReset :: master -> Bool
    allowPasswordReset _ = True

    -- | The page which prompts for a username and sends an email allowing password reset.
    --   By default, it embeds 'resetPasswordWidget'.
    getResetPasswordR :: GHandler Auth master RepHtml
    getResetPasswordR = do
        tm <- getRouteToMaster
        defaultLayout $ do
            setTitleI MsgResetPwdTitle
            resetPasswordWidget tm

    -- | The page which allows the user to set a new password.
    --
    -- This is called only when the email key has been verified as correct. By default, it embeds
    -- 'newPasswordWidget'.
    setPasswordHandler :: UserAccount db -> GHandler Auth master RepHtml
    setPasswordHandler u = do
        tm <- getRouteToMaster
        defaultLayout $ do
            setTitleI Msg.SetPassTitle
            newPasswordWidget u tm

-- | Salt and hash a password.
hashPassword :: MonadIO m => T.Text -> m B.ByteString
hashPassword pwd = liftIO $ PS.makePassword (TE.encodeUtf8 pwd) 12

-- | Verify a password
verifyPassword :: T.Text       -- ^ password
               -> B.ByteString -- ^ hashed password
               -> Bool
verifyPassword pwd = PS.verifyPassword (TE.encodeUtf8 pwd)

-- | Randomly create a new verification key.
newVerifyKey :: MonadIO m => m T.Text
newVerifyKey = do
    g <- liftIO newStdGen
    let bs = B.pack $ take 32 $ randoms g
    return $ TE.decodeUtf8 $ B64.encode bs

---------------------------------------------------------------------------------------------------



-- | Lens getter
infixl 8 ^.
(^.) :: a -> ((b -> Const b b') -> a -> Const b a') -> b
x ^. l = getConst $ l Const x

instance (P.PersistEntity u, PersistUserCredentials u) => UserCredentials (P.Entity u) where
    username u = u ^. fieldLens userUsernameF
    userPasswordHash u = u ^. fieldLens userPasswordHashF
    userEmail u = u ^. fieldLens userEmailF
    userEmailVerified u = u ^. fieldLens userEmailVerifiedF
    userEmailVerifyKey u = u ^. fieldLens userEmailVerifyKeyF
    userResetPwdKey u = u ^. fieldLens userResetPwdKeyF

-- | Internal state for the AccountPersistDB monad.
data PersistFuncs master user sub = PersistFuncs {
      pGet :: T.Text -> GHandler sub master (Maybe (P.Entity user))
    , pInsert :: Username -> user -> GHandler sub master (Either T.Text (P.Entity user))
    , pUpdate :: P.Entity user -> [P.Update user] -> GHandler sub master ()
}

-- | A newtype which when using persistent is an instance of 'AccountDB'.
newtype AccountPersistDB master user sub a = AccountPersistDB (ReaderT (PersistFuncs master user sub) (GHandler sub master) a)
    deriving (Monad, MonadIO)

instance (Yesod master, PersistUserCredentials user) => AccountDB (AccountPersistDB master user) where
    type UserAccount (AccountPersistDB master user) = P.Entity user

    loadUser name = AccountPersistDB $ do
        f <- ask
        lift $ pGet f name

    addNewUser name email key pwd = AccountPersistDB $ do
        f <- ask
        lift $ pInsert f name $ userCreate name email key pwd

    verifyAccount u = AccountPersistDB $ do
        f <- ask
        lift $ pUpdate f u [ userEmailVerifiedF P.=. True
                           , userEmailVerifyKeyF P.=. ""]

    setVerifyKey u key = AccountPersistDB $ do
        f <- ask
        lift $ pUpdate f u [userEmailVerifyKeyF P.=. key]

    setNewPasswordKey u key = AccountPersistDB $ do
        f <- ask
        lift $ pUpdate f u [userResetPwdKeyF P.=. key]

    setNewPassword u pwd = AccountPersistDB $ do
        f <- ask
        lift $ pUpdate f u [ userPasswordHashF P.=. pwd
                           , userResetPwdKeyF P.=. ""]

-- | Use this for 'runAccountDB' if you are using 'AccountPersistDB' as your database type.
runAccountPersistDB :: ( Yesod master
                       , YesodPersist master
                       , P.PersistEntity user
                       , PersistUserCredentials user
                       , b ~ YesodPersistBackend master
#if 1
                       , P.PersistMonadBackend (b (GHandler sub master)) ~ P.PersistEntityBackend user
                       , P.PersistUnique (b (GHandler sub master))
                       , P.PersistQuery (b (GHandler sub master))
#else
                       , b ~ P.PersistEntityBackend user
                       , P.PersistUnique b (GHandler sub master)
                       , P.PersistQuery b (GHandler sub master)
#endif
    
                       ) 
                       => AccountPersistDB master user sub a -> GHandler sub master a
runAccountPersistDB (AccountPersistDB m) = runReaderT m funcs
    where funcs = PersistFuncs {
                      pGet = runDB . P.getBy . uniqueUsername
                    , pInsert = \name u -> do mentity <- runDB $ P.insertBy u
                                              mr <- getMessageRender
                                              case mentity of
                                                 Left _ -> return $ Left $ mr $ MsgUsernameExists name
                                                 Right k -> return $ Right $ P.Entity k u
                    , pUpdate = \(P.Entity key _) u -> runDB $ P.update key u
                    }