import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import 'package:flutter_web_auth_2_platform_interface/flutter_web_auth_2_platform_interface.dart';
import 'package:webview_all/webview_all.dart';

/// Implements the plugin interface using the Webview interface (currently used
/// by Windows and Linux).
class FlutterWebAuth2WebViewPlugin extends FlutterWebAuth2Platform {
  bool _authenticated = false;
  OffscreenWebViewSession? _offscreenSession;
  BuildContext? _dialogContext;
  OverlayEntry? _overlayEntry;
  Timer? _timeoutTimer;
  ValueNotifier<double>? _progressNotifier;
  Completer<String>? _completer;

  @override
  Future<String> authenticate({
    required String url,
    required String callbackUrlScheme,
    required Map<String, dynamic> options,
  }) async {
    if (WebViewPlatform.instance == null) {
      throw StateError('Webview is not available');
    }

    final parsedOptions = FlutterWebAuth2Options.fromJson(options);

    await clearAllDanglingCalls();

    _authenticated = false;
    final c = Completer<String>();
    _completer = c;

    if (parsedOptions.timeout > 0) {
      _timeoutTimer = Timer(Duration(seconds: parsedOptions.timeout), () {
        if (!_authenticated && !c.isCompleted) {
          _cleanUp();
          c.completeError(
            PlatformException(
              code: 'CANCELED',
              message: 'User canceled',
            ),
          );
        }
      });
    }

    if (parsedOptions.silentAuth) {
      try {
        final session = await OffscreenWebViewSession.create();
        _offscreenSession = session;
        final controller = session.controller;

        await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
        await controller.setNavigationDelegate(
          NavigationDelegate(
            onNavigationRequest: (request) {
              if (_isCallbackUrl(
                  request.url, callbackUrlScheme, parsedOptions)) {
                _handleSuccess(request.url, c);
                return NavigationDecision.prevent;
              }
              return NavigationDecision.navigate;
            },
            onUrlChange: (change) {
              final newUrl = change.url;
              if (newUrl != null &&
                  _isCallbackUrl(newUrl, callbackUrlScheme, parsedOptions)) {
                _handleSuccess(newUrl, c);
              }
            },
            onPageStarted: (startedUrl) {
              if (_isCallbackUrl(
                  startedUrl, callbackUrlScheme, parsedOptions)) {
                _handleSuccess(startedUrl, c);
              }
            },
            onWebResourceError: (error) {
              if (error.url != null &&
                  _isCallbackUrl(
                      error.url!, callbackUrlScheme, parsedOptions)) {
                _handleSuccess(error.url!, c);
              }
            },
          ),
        );
        await controller.loadRequest(Uri.parse(url));
        return await c.future;
      } catch (e) {
        _cleanUp();
        if (!c.isCompleted) {
          c.completeError(e);
        }
        return await c.future;
      }
    }

    final progressNotifier = ValueNotifier<double>(0.0);
    _progressNotifier = progressNotifier;

    final controller = WebViewController();

    await controller.setJavaScriptMode(JavaScriptMode.unrestricted);
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          if (_isCallbackUrl(request.url, callbackUrlScheme, parsedOptions)) {
            _handleSuccess(request.url, c);
            return NavigationDecision.prevent;
          }
          return NavigationDecision.navigate;
        },
        onUrlChange: (change) {
          final newUrl = change.url;
          if (newUrl != null &&
              _isCallbackUrl(newUrl, callbackUrlScheme, parsedOptions)) {
            _handleSuccess(newUrl, c);
          }
        },
        onPageStarted: (startedUrl) {
          if (_isCallbackUrl(startedUrl, callbackUrlScheme, parsedOptions)) {
            _handleSuccess(startedUrl, c);
          }
        },
        onProgress: (progress) {
          progressNotifier.value = progress / 100.0;
        },
        onWebResourceError: (error) {
          if (error.url != null &&
              _isCallbackUrl(error.url!, callbackUrlScheme, parsedOptions)) {
            _handleSuccess(error.url!, c);
          }
        },
      ),
    );

    await controller.loadRequest(Uri.parse(url));

    final nav = _findNavigatorState();
    if (nav != null && nav.mounted) {
      unawaited(
        showDialog<void>(
          context: nav.context,
          useRootNavigator: true,
          barrierDismissible: true,
          builder: (dialogContext) {
            _dialogContext = dialogContext;
            return _AuthWebViewDialog(
              controller: controller,
              progressNotifier: progressNotifier,
              onClose: () {
                if (dialogContext.mounted &&
                    Navigator.of(dialogContext).canPop()) {
                  Navigator.of(dialogContext).pop();
                }
              },
            );
          },
        ).then((_) {
          _dialogContext = null;
          if (!_authenticated && !c.isCompleted) {
            c.completeError(
              PlatformException(code: 'CANCELED', message: 'User canceled'),
            );
          }
          _cleanUp();
        }),
      );
    } else {
      final overlay = _findOverlayState();
      if (overlay != null) {
        _overlayEntry = OverlayEntry(
          builder: (context) {
            return Stack(
              children: [
                Positioned.fill(
                  child: ModalBarrier(
                    color: Colors.black54,
                    dismissible: true,
                    onDismiss: () {
                      if (!_authenticated && !c.isCompleted) {
                        c.completeError(
                          PlatformException(
                            code: 'CANCELED',
                            message: 'User canceled',
                          ),
                        );
                      }
                      _cleanUp();
                    },
                  ),
                ),
                Center(
                  child: _AuthWebViewDialog(
                    controller: controller,
                    progressNotifier: progressNotifier,
                    onClose: () {
                      if (!_authenticated && !c.isCompleted) {
                        c.completeError(
                          PlatformException(
                            code: 'CANCELED',
                            message: 'User canceled',
                          ),
                        );
                      }
                      _cleanUp();
                    },
                  ),
                ),
              ],
            );
          },
        );
        overlay.insert(_overlayEntry!);
      } else {
        // Fallback for headless environments: let offscreen session handle it.
        try {
          final session =
              await OffscreenWebViewSession.fromController(controller);
          _offscreenSession = session;
        } catch (_) {}
      }
    }

    return c.future;
  }

  void _handleSuccess(String callbackUrl, Completer<String> c) {
    if (_authenticated) {
      return;
    }
    _authenticated = true;
    _cleanUp();
    if (!c.isCompleted) {
      c.complete(callbackUrl);
    }
  }

  bool _isCallbackUrl(
    String url,
    String callbackUrlScheme,
    FlutterWebAuth2Options options,
  ) {
    try {
      final uri = Uri.parse(url);
      if (uri.scheme.toLowerCase() != callbackUrlScheme.toLowerCase()) {
        return false;
      }
      if (options.httpsHost != null && uri.host != options.httpsHost) {
        return false;
      }
      if (options.httpsPath != null && uri.path != options.httpsPath) {
        return false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  NavigatorState? _findNavigatorState() {
    NavigatorState? result;
    void visitor(Element element) {
      if (result != null) {
        return;
      }
      if (element is StatefulElement && element.state is NavigatorState) {
        result = element.state as NavigatorState;
        return;
      }
      element.visitChildren(visitor);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) {
      visitor(root);
    }
    return result;
  }

  OverlayState? _findOverlayState() {
    OverlayState? result;
    void visitor(Element element) {
      if (result != null) {
        return;
      }
      if (element is StatefulElement && element.state is OverlayState) {
        result = element.state as OverlayState;
        return;
      }
      element.visitChildren(visitor);
    }

    final root = WidgetsBinding.instance.rootElement;
    if (root != null) {
      visitor(root);
    }
    return result;
  }

  void _cleanUp() {
    _timeoutTimer?.cancel();
    _timeoutTimer = null;

    if (_dialogContext != null && _dialogContext!.mounted) {
      if (Navigator.of(_dialogContext!).canPop()) {
        Navigator.of(_dialogContext!).pop();
      }
      _dialogContext = null;
    }

    if (_overlayEntry != null) {
      _overlayEntry?.remove();
      _overlayEntry?.dispose();
      _overlayEntry = null;
    }

    _offscreenSession?.close();
    _offscreenSession = null;

    _progressNotifier?.dispose();
    _progressNotifier = null;
  }

  @override
  Future<void> clearAllDanglingCalls() async {
    if (_completer != null && !_completer!.isCompleted) {
      _completer!.completeError(
        PlatformException(code: 'CANCELED', message: 'User canceled'),
      );
    }
    _cleanUp();
  }
}

class _AuthWebViewDialog extends StatelessWidget {
  const _AuthWebViewDialog({
    required this.controller,
    required this.onClose,
    this.progressNotifier,
  });

  final WebViewController controller;
  final VoidCallback onClose;
  final ValueNotifier<double>? progressNotifier;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = (size.width * 0.85).clamp(360.0, 1100.0);
    final height = (size.height * 0.85).clamp(450.0, 750.0);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: SizedBox(
        width: width,
        height: height,
        child: Column(
          children: [
            Container(
              height: 48,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: Theme.of(context).dividerColor,
                    width: 1,
                  ),
                ),
              ),
              child: Row(
                children: [
                  const Text(
                    'Authenticate',
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: 'Close',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
            if (progressNotifier != null)
              ValueListenableBuilder<double>(
                valueListenable: progressNotifier!,
                builder: (context, progress, _) {
                  if (progress >= 1.0) {
                    return const SizedBox.shrink();
                  }
                  return LinearProgressIndicator(
                    value: progress > 0 ? progress : null,
                    minHeight: 2,
                  );
                },
              ),
            Expanded(
              child: WebViewWidget(controller: controller),
            ),
          ],
        ),
      ),
    );
  }
}
