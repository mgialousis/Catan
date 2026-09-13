import 'dart:js_interop';

// Per-tab storage survives reload without letting another tab overwrite its intent.
@JS('window.sessionStorage.getItem')
external JSString? _get(JSString key);
@JS('window.sessionStorage.setItem')
external void _set(JSString key, JSString value);
@JS('window.sessionStorage.removeItem')
external void _remove(JSString key);

String? readIntent(String key) => _get(key.toJS)?.toDart;
void writeIntent(String key, String? value) {
  if (value == null) {
    _remove(key.toJS);
  } else {
    _set(key.toJS, value.toJS);
  }
}
