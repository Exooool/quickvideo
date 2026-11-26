part of 'catalog.dart';

class CspPlugin {
  const CspPlugin(this.sha256, this.md5);

  static const _channel = MethodChannel('quickvideo/csp');
  final String sha256;
  final String md5;

  static CspPlugin? fromJson(Object? value) {
    if (value is! Map || value['sha256'] is! String || value['md5'] is! String) return null;
    return CspPlugin(value['sha256'] as String, value['md5'] as String);
  }

  Json toJson() => {'sha256': sha256, 'md5': md5};

  static Future<CspPlugin?> pick() async => fromJson(await _invoke<Object?>('pick'));

  Future<void> check() async {
    await _invoke<bool>('check', {'sha256': sha256}).timeout(const Duration(seconds: 6));
  }

  Future<Json> invoke(_CmsSite site, String method, Json parameters) async {
    final text = await _invoke<String>(method, {
      'sha256': sha256,
      'api': site.cspApi,
      'ext': site.ext,
      ...parameters,
    }).timeout(const Duration(seconds: 10), onTimeout: () {
      throw const FormatException('CSP 插件请求超时');
    });
    final response = TvboxGateway._json(text ?? '', 'CSP 插件返回的 JSON 无效');
    if (response is! Json) throw const FormatException('CSP 插件返回的 JSON 不是对象');
    return response;
  }

  static Future<T?> _invoke<T>(String method, [Json? arguments]) async {
    try {
      return await _channel.invokeMethod<T>(method, arguments);
    } on MissingPluginException {
      throw const FormatException('请运行 py -3 setup_android.py 并重新安装 App');
    } on PlatformException catch (error) {
      throw FormatException(error.message ?? 'Android CSP 插件操作失败');
    }
  }
}
