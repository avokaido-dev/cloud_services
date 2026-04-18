import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Status of the user's current session, driving the router.
enum AuthStatus {
  /// No Firebase user.
  signedOut,

  /// Signed in, but we haven't read custom claims yet.
  signedInPending,

  /// Signed in and needs to create (or join) a workspace.
  signedInNoWorkspace,

  /// Signed in and belongs to a workspace.
  signedInWithWorkspace,
}

/// Wraps [FirebaseAuth] to expose a simple status stream for go_router.
///
/// End users sign in via GitHub, Google, Microsoft, or Apple OAuth, with
/// email/password as a fallback.
class AuthService extends ChangeNotifier {
  AuthService({FirebaseAuth? auth}) : _auth = auth ?? FirebaseAuth.instance {
    _auth.authStateChanges().listen(_onAuthChanged);
    _handlePendingRedirect();
    _handlePendingEmailLink();
  }

  static const _pendingEmailKey = 'avokaido.pendingEmailLinkEmail';

  final FirebaseAuth _auth;

  AuthStatus _status = AuthStatus.signedOut;
  User? _user;
  String? _workspaceId;
  String? _workspaceRole;
  String? _errorMessage;

  AuthStatus get status => _status;
  User? get user => _user;
  String? get workspaceId => _workspaceId;
  String? get workspaceRole => _workspaceRole;
  bool get isOrgAdmin => _workspaceRole == 'admin';
  String? get errorMessage => _errorMessage;

  bool _pendingEmailLinkNeedsEmail = false;
  bool get pendingEmailLinkNeedsEmail => _pendingEmailLinkNeedsEmail;

  // ---------------------------------------------------------------------------
  // Sign-in entry points
  // ---------------------------------------------------------------------------

  Future<void> signInWithGithub() => _signInWith(GithubAuthProvider());

  Future<void> signInWithGoogle() => _signInWith(
        GoogleAuthProvider()
          ..addScope('email')
          ..addScope('profile'),
      );

  Future<void> signInWithMicrosoft() =>
      _signInWith(OAuthProvider('microsoft.com'));

  // Apple web sign-in requires the `email` and `name` scopes to be requested
  // explicitly, otherwise Firebase returns no user profile data.
  Future<void> signInWithApple() => _signInWith(
        OAuthProvider('apple.com')
          ..addScope('email')
          ..addScope('name'),
      );

  // Picks up the OAuth result after a redirect-based sign-in completes.
  // Errors (e.g. provider not configured) surface here rather than in
  // _signInWith, because the page navigates away before _signInWith returns.
  Future<void> _handlePendingRedirect() async {
    try {
      await _auth.getRedirectResult();
    } on FirebaseAuthException catch (e) {
      _errorMessage = e.message ?? e.code;
      notifyListeners();
    } catch (e) {
      _errorMessage = e.toString();
      notifyListeners();
    }
  }

  // Passwordless invite links: the admin's `sendInvite` function emails a
  // `generateSignInWithEmailLink` URL that redirects back to `/signin?...`.
  // We detect the link on load and — if the email is cached from the same
  // browser — complete the sign-in automatically. If not (e.g. the recipient
  // clicked the link on a different device), we flip a flag so the UI can
  // prompt them to type their email, then call [completeEmailLinkSignIn].
  Future<void> _handlePendingEmailLink() async {
    final currentUrl = web.window.location.href;
    if (!_auth.isSignInWithEmailLink(currentUrl)) return;

    final cachedEmail =
        web.window.localStorage.getItem(_pendingEmailKey);
    if (cachedEmail != null && cachedEmail.isNotEmpty) {
      await completeEmailLinkSignIn(cachedEmail);
    } else {
      _pendingEmailLinkNeedsEmail = true;
      notifyListeners();
    }
  }

  Future<void> completeEmailLinkSignIn(String email) async {
    _errorMessage = null;
    final currentUrl = web.window.location.href;
    try {
      await _auth.signInWithEmailLink(
        email: email.trim(),
        emailLink: currentUrl,
      );
      web.window.localStorage.removeItem(_pendingEmailKey);
      _pendingEmailLinkNeedsEmail = false;
      // Strip the long query string from the address bar once consumed.
      web.window.history.replaceState(null, '', '/#/signin');
    } on FirebaseAuthException catch (e) {
      _errorMessage = e.message ?? e.code;
    } catch (e) {
      _errorMessage = e.toString();
    }
    notifyListeners();
  }

  Future<void> _signInWith(AuthProvider provider) async {
    _errorMessage = null;
    try {
      await _auth.signInWithRedirect(provider);
    } on FirebaseAuthException catch (e) {
      _errorMessage = e.message ?? e.code;
      notifyListeners();
    } catch (e) {
      _errorMessage = e.toString();
      notifyListeners();
    }
  }

  // Email+password is a fallback path — OAuth (GitHub / Microsoft / Apple)
  // is the primary sign-in method.

  Future<void> signUpWithEmail({
    required String email,
    required String password,
  }) async {
    _errorMessage = null;
    try {
      await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } on FirebaseAuthException catch (e) {
      _errorMessage = e.message ?? e.code;
      notifyListeners();
    }
  }

  Future<void> signInWithEmail({
    required String email,
    required String password,
  }) async {
    _errorMessage = null;
    try {
      await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password,
      );
    } on FirebaseAuthException catch (e) {
      _errorMessage = e.message ?? e.code;
      notifyListeners();
    }
  }

  Future<void> sendPasswordResetEmail(String email) async {
    _errorMessage = null;
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (e) {
      _errorMessage = e.message ?? e.code;
      notifyListeners();
    }
  }

  Future<void> signOut() => _auth.signOut();

  /// Forces the ID token to refresh so custom claims (e.g. a just-created
  /// workspaceId) propagate immediately instead of waiting for the 1-hour
  /// token rotation.
  Future<void> refreshClaims() async {
    if (_user == null) return;
    await _user!.getIdToken(true);
    await _onAuthChanged(_auth.currentUser);
  }

  Future<void> _onAuthChanged(User? user) async {
    _user = user;
    if (user == null) {
      _status = AuthStatus.signedOut;
      _workspaceId = null;
      _workspaceRole = null;
      notifyListeners();
      return;
    }

    _status = AuthStatus.signedInPending;
    notifyListeners();

    // Force-refresh to pull the freshest custom claims.
    var token = await user.getIdTokenResult(true);
    _workspaceId = token.claims?['workspaceId'] as String?;
    _workspaceRole = token.claims?['workspaceRole'] as String?;

    // No workspace yet — ask the backend whether the caller's email domain
    // already maps to an org. If it does, the function auto-joins them as a
    // member and we re-read claims. If not, fall through to the create-
    // workspace flow (where they'll become the admin for their domain).
    //
    // Hard timeout so a missing / misconfigured function never strands the
    // UI in `signedInPending` — we'd rather route to create-workspace than
    // show a blank loading state indefinitely.
    if (_workspaceId == null || _workspaceId!.isEmpty) {
      try {
        final result = await FirebaseFunctions.instance
            .httpsCallable('resolveWorkspaceForUser')
            .call<Map<String, dynamic>>()
            .timeout(const Duration(seconds: 8));
        final joined = result.data['joined'] as bool? ?? false;
        if (joined) {
          token = await user.getIdTokenResult(true);
          _workspaceId = token.claims?['workspaceId'] as String?;
          _workspaceRole = token.claims?['workspaceRole'] as String?;
        }
      } catch (e) {
        // Non-fatal: if the lookup fails or times out, proceed as if no
        // workspace was found so the user can still create one manually.
        debugPrint('[auth] resolveWorkspaceForUser failed: $e');
      }
    }

    _status = (_workspaceId == null || _workspaceId!.isEmpty)
        ? AuthStatus.signedInNoWorkspace
        : AuthStatus.signedInWithWorkspace;
    notifyListeners();
  }
}
