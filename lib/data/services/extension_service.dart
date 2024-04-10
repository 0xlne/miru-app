import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:html/dom.dart';
import 'package:html/parser.dart';
import 'package:miru_app/data/services/extension_jscore_plugin.dart';
import 'package:miru_app/utils/log.dart';
import 'package:miru_app/utils/miru_storage.dart';
import 'package:miru_app/utils/request.dart';
import 'package:xpath_selector_html_parser/xpath_selector_html_parser.dart';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:miru_app/models/index.dart';
import 'package:miru_app/data/services/database_service.dart';
import 'package:miru_app/utils/extension.dart';

class ExtensionService {
  late JavascriptRuntime runtime;
  late Extension extension;
  String _cuurentRequestUrl = '';
  String evalString = '';
  JsBridge? jsBridge;
  static Map<dynamic, dynamic> evalMap = {};
  String className = '';
  bool isinit = false;
  initRuntime(Extension ext) async {
    extension = ext;
    className = extension.package.replaceAll('.', '');
    if (!className.isAlphabetOnly) {
      className = "${className.replaceAll(RegExp(r'\d'), '')}Renamed";
    }
    // 读取文件
    final file =
        File('${ExtensionUtils.extensionsDir}/${extension.package}.js');
    final content = file.readAsStringSync();

    // 初始化runtime
    runtime = getJavascriptRuntime();
    jsBridge = JsBridge(jsRuntime: runtime);
    // 注册方法
    // 日志
    runtime.onMessage('log', (dynamic args) {
      // debugPrint(args[0]);
      ExtensionUtils.addLog(
        extension,
        ExtensionLogLevel.info,
        args[0],
      );
    });
    Future<dynamic> jsRequest(dynamic args) async {
      _cuurentRequestUrl = args[0];
      final headers = args[1]['headers'] ?? {};
      if (headers['User-Agent'] == null) {
        headers['User-Agent'] = MiruStorage.getUASetting();
      }

      final url = args[0];
      final method = args[1]['method'] ?? 'get';
      final requestBody = args[1]['data'];

      final log = ExtensionNetworkLog(
        extension: extension,
        url: args[0],
        method: method,
        requestHeaders: headers,
      );
      final key = UniqueKey().toString();
      ExtensionUtils.addNetworkLog(
        key,
        log,
      );

      try {
        final res = await dio.request<String>(
          url,
          data: requestBody,
          queryParameters: args[1]['queryParameters'] ?? {},
          options: Options(
            headers: headers,
            method: method,
          ),
        );
        log.requestHeaders = res.requestOptions.headers;
        log.responseBody = res.data;
        log.responseHeaders = res.headers.map.map(
          (key, value) => MapEntry(
            key,
            value.join(';'),
          ),
        );
        log.statusCode = res.statusCode;

        ExtensionUtils.addNetworkLog(
          key,
          log,
        );
        return res.data;
      } on DioException catch (e) {
        log.url = e.requestOptions.uri.toString();
        log.requestHeaders = e.requestOptions.headers;
        log.responseBody = e.response?.data;
        log.responseHeaders = e.response?.headers.map.map(
          (key, value) => MapEntry(
            key,
            value.join(';'),
          ),
        );
        log.statusCode = e.response?.statusCode;
        ExtensionUtils.addNetworkLog(
          key,
          log,
        );
        rethrow;
      }
    }

    // 请求
    runtime.onMessage('request', (args) => jsRequest(args));

    // 设置
    runtime.onMessage('registerSetting', (dynamic args) async {
      args[0]['package'] = extension.package;

      return DatabaseService.registerExtensionSetting(
        ExtensionSetting()
          ..package = extension.package
          ..title = args[0]['title']
          ..key = args[0]['key']
          ..value = args[0]['value']
          ..type = ExtensionSetting.stringToType(args[0]['type'])
          ..description = args[0]['description']
          ..defaultValue = args[0]['defaultValue']
          ..options = jsonEncode(args[0]['options']),
      );
    });
    runtime.onMessage('getSetting', (dynamic args) async {
      final setting =
          await DatabaseService.getExtensionSetting(extension.package, args[0]);
      return setting!.value ?? setting.defaultValue;
    });

    // 清理扩展设置
    runtime.onMessage('cleanSettings', (dynamic args) async {
      // debugPrint('cleanSettings: ${args[0]}');
      return DatabaseService.cleanExtensionSettings(
          extension.package, List<String>.from(args[0]));
    });

    // css 选择器
    runtime.onMessage('querySelector', (dynamic args) {
      final content = args[0];
      final selector = args[1];
      final fun = args[2];

      final doc = parse(content).querySelector(selector);

      switch (fun) {
        case 'text':
          return doc?.text ?? '';
        case 'outerHTML':
          return doc?.outerHtml ?? '';
        case 'innerHTML':
          return doc?.innerHtml ?? '';
        default:
          return doc?.outerHtml ?? '';
      }
    });

    // xpath 选择器
    runtime.onMessage('queryXPath', (args) {
      final content = args[0];
      final selector = args[1];
      final fun = args[2];

      final xpath = HtmlXPath.html(content);
      final result = xpath.queryXPath(selector);

      switch (fun) {
        case 'attr':
          return result.attr ?? '';
        case 'attrs':
          return jsonEncode(result.attrs);
        case 'text':
          return result.node?.text;
        case 'allHTML':
          return result.nodes
              .map((e) => (e.node as Element).outerHtml)
              .toList();
        case 'outerHTML':
          return (result.node?.node as Element).outerHtml;
        default:
          return result.node?.text;
      }
    });

    runtime.onMessage('removeSelector', (dynamic args) {
      final content = args[0];
      final selector = args[1];
      final doc = parse(content);
      doc.querySelectorAll(selector).forEach((element) {
        element.remove();
      });
      return doc.outerHtml;
    });

    // 获取标签属性
    runtime.onMessage('getAttributeText', (args) {
      final content = args[0];
      final selector = args[1];
      final attr = args[2];
      final doc = parse(content).querySelector(selector);
      return doc?.attributes[attr];
    });

    runtime.onMessage('querySelectorAll', (dynamic args) async {
      final content = args[0];
      final selector = args[1];
      final doc = parse(content).querySelectorAll(selector);
      final elements = jsonEncode(doc.map((e) {
        return e.outerHtml;
      }).toList());
      return elements;
    });

    if (Platform.isLinux) {
      jsBridge!.setHandler('request$className', (arg) async {
        final message = jsonDecode(arg);
        _cuurentRequestUrl = message[0];
        final options = message[1];
        final headers = options['headers'] ?? {};
        if (headers['User-Agent'] == null) {
          headers['User-Agent'] = MiruStorage.getUASetting();
        }

        final log = ExtensionNetworkLog(
          extension: extension,
          url: _cuurentRequestUrl,
          method: options['method'],
          requestHeaders: headers,
        );
        final key = UniqueKey().toString();
        ExtensionUtils.addNetworkLog(
          key,
          log,
        );

        try {
          final res = await dio.request<String>(
            _cuurentRequestUrl,
            data: options['data'],
            queryParameters: options['queryParameters'] ?? {},
            options: Options(
              headers: headers,
              method: options['method'],
            ),
          );
          log.requestHeaders = res.requestOptions.headers;
          log.responseBody = res.data;
          log.responseHeaders = res.headers.map.map(
            (key, value) => MapEntry(
              key,
              value.join(';'),
            ),
          );
          log.statusCode = res.statusCode;

          ExtensionUtils.addNetworkLog(
            key,
            log,
          );
          // await runtime
          //     .handlePromise(await runtime.evaluateAsync(evalMap[package]));
          await jsBridge!.sendMessage('request$className', res.data);
        } on DioException catch (e) {
          log.url = e.requestOptions.uri.toString();
          log.requestHeaders = e.requestOptions.headers;
          log.responseBody = e.response?.data;
          log.responseHeaders = e.response?.headers.map.map(
            (key, value) => MapEntry(
              key,
              value.join(';'),
            ),
          );
          log.statusCode = e.response?.statusCode;
          ExtensionUtils.addNetworkLog(
            key,
            log,
          );
          rethrow;
        }
      });
      jsBridge!.setHandler('log$className', (dynamic message) async {
        final args = jsonDecode(message);
        logger.info(args[0]);
        ExtensionUtils.addLog(
          extension,
          ExtensionLogLevel.info,
          args[0],
        );
      });
      jsBridge!.setHandler("getAttributeText$className", (message) async {
        final args = jsonDecode(message);
        final content = args[0];
        final selector = args[1];
        final attr = args[2];
        final doc = parse(content).querySelector(selector);
        await jsBridge!
            .sendMessage('getAttributeText$className', doc?.attributes[attr]);
      });
      jsBridge!.setHandler('querySelectorAll$className',
          (dynamic message) async {
        final args = jsonDecode(message);
        final content = args["content"];
        final selector = args["selector"];
        final doc = parse(content).querySelectorAll(selector);
        final elements = jsonEncode(doc.map((e) {
          return e.outerHtml;
        }).toList());
        await jsBridge!.sendMessage('querySelectorAll$className', elements);
      });
      jsBridge!.setHandler('querySelector$className', (message) async {
        final args = jsonDecode(message);
        final content = args[0];
        final selector = args[1];
        final fun = args[2];

        final doc = parse(content).querySelector(selector);
        String result = '';
        switch (fun) {
          case 'text':
            result = doc?.text ?? '';
          case 'outerHTML':
            result = doc?.outerHtml ?? '';
          case 'innerHTML':
            result = doc?.innerHtml ?? '';
          default:
            result = doc?.outerHtml ?? '';
        }
        await jsBridge!.sendMessage('querySelector$className', result);
      });
      jsBridge!.setHandler('registerSetting$className', (dynamic args) async {
        args[0]['package'] = extension.package;
        jsBridge!.sendMessage(
            'registerSetting$className',
            DatabaseService.registerExtensionSetting(
              ExtensionSetting()
                ..package = extension.package
                ..title = args[0]['title']
                ..key = args[0]['key']
                ..value = args[0]['value']
                ..type = ExtensionSetting.stringToType(args[0]['type'])
                ..description = args[0]['description']
                ..defaultValue = args[0]['defaultValue']
                ..options = jsonEncode(args[0]['options']),
            ));
      });
    }
    // 初始化运行扩展
    await _initRunExtension(content);
    return this;
  }

  _initRunExtension(String extScript) async {
    final cryptoJs = await rootBundle.loadString('assets/js/CryptoJS.min.js');
    final jsencrypt = await rootBundle.loadString('assets/js/jsencrypt.min.js');
    final md5 = await rootBundle.loadString('assets/js/md5.min.js');
    runtime.evaluate(Platform.isLinux
        ? '''
$cryptoJs
$jsencrypt
$md5
class Element {
  constructor(content, selector) {
    this.content = content;
    this.selector = selector || "";
  }
  async querySelector(selector) {
    return new Element(await this.execute(), selector);
  }

  async execute(fun) {
    const waitForChange  = new Promise(resolve=>{DartBridge.setHandler("querySelector$className", async (arg) => {
      resolve(arg);
    })});
    DartBridge.sendMessage("querySelector$className",  JSON.stringify([this.content, this.selector, fun]));
    const elements = await waitForChange;
    // console.log('dart bridge passed -- querySelector')
    return elements;
  }

  async removeSelector(selector) {
    this.content = await sendMessage(
      "removeSelector",
      JSON.stringify([await this.outerHTML, selector])
    );
    return this;
  }

  async getAttributeText(attr) {
    const waitForChange  = new Promise(resolve=>{DartBridge.setHandler("getAttributeText$className", async (arg) => {
      resolve(arg);
    })});
    DartBridge.sendMessage("getAttributeText$className",  JSON.stringify([await this.outerHTML, this.selector, attr]));
    const elements = await waitForChange;
    return elements;
  }

  get text() {
    return this.execute("text");
  }

  get outerHTML() {
    return this.execute("outerHTML");
  }

  get innerHTML() {
    return this.execute("innerHTML");
  }
}
class XPathNode {
  constructor(content, selector) {
    this.content = content;
    this.selector = selector;
  }

  async excute(fun) {
    return await sendMessage(
      "queryXPath",
      JSON.stringify([this.content, this.selector, fun])
    );
  }

  get attr() {
    return this.excute("attr");
  }

  get attrs() {
    return this.excute("attrs");
  }

  get text() {
    return this.excute("text");
  }
  
  get allHTML() {
    return this.excute("allHTML");
  }

  get outerHTML() {
    return this.excute("outerHTML");
  }
}

// 重写 console.log
console.log = function (message) {
  if (typeof message === "object") {
    message = JSON.stringify(message);
  }
  DartBridge.sendMessage("log$className", JSON.stringify([message.toString()]));
};
class Extension {
  package = "${extension.package}";
  name = "${extension.name}";
  // 在 load 中注册的 keys
  settingKeys = [];
  
  querySelector(content, selector) {
    return new Element(content, selector);
  }
   async request(url, options) {
    options = options || {};
    options.headers = options.headers || {};
    const miruUrl = options.headers["Miru-Url"] || "${extension.webSite}";
    options.method = options.method || "get";
    var message = null
    const waitForChange = new Promise(resolve => {
      DartBridge.setHandler("request$className", async (res) => {
        try {
          message = JSON.parse(res);
        } catch (e) {
          message = res;
        }
        resolve();
      });
    });

    DartBridge.sendMessage("request$className", JSON.stringify([miruUrl + url, options,"${extension.package}"]));
    await waitForChange;
    return message;
  }
  queryXPath(content, selector) {
    return new XPathNode(content, selector);
  }
  async querySelectorAll(content, selector) {
    const waitForChange  = new Promise(resolve=>{DartBridge.setHandler("querySelectorAll$className", async (arg) => {
      const  elements = [];
      const message = JSON.parse(arg);
      for(const e of message){
        elements.push(new Element(e, selector));
      }
      resolve(elements);
    })});
    DartBridge.sendMessage("querySelectorAll$className",  JSON.stringify({content:content,selector:selector}));
    const elements = await waitForChange;
    return elements;
  }
  async getAttributeText(content, selector, attr) {
    const waitForChange  = new Promise(resolve=>{DartBridge.setHandler("getAttributeText$className", async (arg) => {
      resolve(arg);
    })});
    DartBridge.sendMessage("getAttributeText$className",  JSON.stringify([content, selector, attr]));
    const elements = await waitForChange;
    return elements;
  }
  latest(page) {
    throw new Error("not implement latest");
  }
  search(kw, page, filter) {
    throw new Error("not implement search");
  }
  createFilter(filter){
    throw new Error("not implement createFilter");
  }
  detail(url) {
    throw new Error("not implement detail");
  }
  watch(url) {
    throw new Error("not implement watch");
  }
  checkUpdate(url) {
    throw new Error("not implement checkUpdate");
  }
  async getSetting(key) {
    return sendMessage("getSetting", JSON.stringify([key]));
  }
  async registerSetting(settings) {
    console.log(JSON.stringify([settings]));
    this.settingKeys.push(settings.key);
    const waitForChange  = new Promise(resolve=>{DartBridge.setHandler("registerSetting$className", async (arg) => {
      resolve(arg);
    })});
    DartBridge.sendMessage("registerSetting$className",  JSON.stringify([settings]));
    const elements = await waitForChange;
    return elements;
  }
  async load() {}
}

async function stringify(callback) {
  const data = await callback();
  return typeof data === "object" ? JSON.stringify(data,0,2) : data;
}



            '''
        : '''
          // 重写 console.log
          var window = (global = globalThis);
          $cryptoJs
          $jsencrypt
          $md5
          class Element {
            constructor(content, selector) {
              this.content = content;
              this.selector = selector || "";
            }

            async querySelector(selector) {
              return new Element(await this.excute(), selector);
            }

            async excute(fun) {
              return await sendMessage(
                "querySelector",
                JSON.stringify([this.content, this.selector, fun])
              );
            }

            async removeSelector(selector) {
              this.content = await sendMessage(
                "removeSelector",
                JSON.stringify([await this.outerHTML, selector])
              );
              return this;
            }

            async getAttributeText(attr) {
              return await sendMessage(
                "getAttributeText",
                JSON.stringify([await this.outerHTML, this.selector, attr])
              );
            }

            get text() {
              return this.excute("text");
            }

            get outerHTML() {
              return this.excute("outerHTML");
            }

            get innerHTML() {
              return this.excute("innerHTML");
            }
          }
          class XPathNode {
            constructor(content, selector) {
              this.content = content;
              this.selector = selector;
            }

            async excute(fun) {
              return await sendMessage(
                "queryXPath",
                JSON.stringify([this.content, this.selector, fun])
              );
            }

            get attr() {
              return this.excute("attr");
            }

            get attrs() {
              return this.excute("attrs");
            }

            get text() {
              return this.excute("text");
            }
            
            get allHTML() {
              return this.excute("allHTML");
            }

            get outerHTML() {
              return this.excute("outerHTML");
            }
          }

          
          console.log = function (message) {
            if (typeof message === "object") {
              message = JSON.stringify(message);
            }
            sendMessage("log", JSON.stringify([message.toString()]));
          };
          class Extension {
            package = "${extension.package}";
            name = "${extension.name}";
            // 在 load 中注册的 keys
            settingKeys = [];
            
            querySelector(content, selector) {
              return new Element(content, selector);
            }
            async request(url, options) {
              options = options || {};
              options.headers = options.headers || {};
              const miruUrl = options.headers["Miru-Url"] || "${extension.webSite}";
              options.method = options.method || "get";
              const res = await sendMessage(
                "request$className",
                JSON.stringify([miruUrl + url, options])
              );

              try {
                return JSON.parse(res);
              } catch (e) {
                return res;
              }
            }
            queryXPath(content, selector) {
              return new XPathNode(content, selector);
            }
            async querySelectorAll(content, selector) {
              let elements = [];
              JSON.parse(
                await sendMessage("querySelectorAll", JSON.stringify([content, selector]))
              ).forEach((e) => {
                elements.push(new Element(e, selector));
              });
              return elements;
            }
            async getAttributeText(content, selector, attr) {
              return await sendMessage(
                "getAttributeText",
                JSON.stringify([content, selector, attr])
              );
            }
            popular(page) {
              throw new Error("not implement popular");
            }
            latest(page) {
              throw new Error("not implement latest");
            }
            search(kw, page, filter) {
              throw new Error("not implement search");
            }
            createFilter(filter){
              throw new Error("not implement createFilter");
            }
            detail(url) {
              throw new Error("not implement detail");
            }
            watch(url) {
              throw new Error("not implement watch");
            }
            checkUpdate(url) {
              throw new Error("not implement checkUpdate");
            }
            async getSetting(key) {
              return sendMessage("getSetting", JSON.stringify([key]));
            }
            async registerSetting(settings) {
              console.log(JSON.stringify([settings]));
              this.settingKeys.push(settings.key);
              return sendMessage("registerSetting", JSON.stringify([settings]));
            }
            async load() {}
          }

          async function stringify(callback) {
            const data = await callback();
            return typeof data === "object" ? JSON.stringify(data,0,2) : data;
          }

    ''');

    final ext = extScript.replaceAll(RegExp(r'export default class.*'),
        'class $className extends Extension {');

    runtime.evaluate('''
      $ext
      if(typeof ${className}Instance !== 'undefined'){
        delete ${className}Instance;
      }
      var ${className}Instance = new $className();
      ${className}Instance.load().then(()=>{
        sendMessage("cleanSettings", JSON.stringify([extension.settingKeys]));
      });
    ''');
    isinit = true;
  }

  // 清理 cookie
  cleanCookie() async {
    await MiruRequest.cleanCookie(extension.webSite);
  }

  /// 添加 cookie
  /// key=value; key=value
  setCookie(String cookies) async {
    await MiruRequest.setCookie(cookies, extension.webSite);
  }

  // 列出所有的 cookie
  Future<String> listCookie() async {
    return await MiruRequest.getCookie(extension.webSite);
  }

  Future<T> runExtension<T>(Future<T> Function() fun) async {
    try {
      return await fun();
    } catch (e) {
      ExtensionUtils.addLog(
        extension,
        ExtensionLogLevel.error,
        e.toString(),
      );
      rethrow;
    }
  }

  Future<Map<String, String>> get _defaultHeaders async {
    return {
      "Referer": _cuurentRequestUrl,
      "User-Agent": MiruStorage.getUASetting(),
      "Cookie": await listCookie(),
    };
  }

  Future<List<ExtensionListItem>> latest(int page) async {
    return runExtension(() async {
      final jsResult = await runtime.handlePromise(
        await runtime.evaluateAsync(Platform.isLinux
            ? '${className}Instance.latest($page)'
            : 'stringify(()=>extension.latest($page))'),
      );

      List<ExtensionListItem> result =
          jsonDecode(jsResult.stringResult).map<ExtensionListItem>((e) {
        return ExtensionListItem.fromJson(e);
      }).toList();
      for (var element in result) {
        element.headers ??= await _defaultHeaders;
      }
      return result;
    });
  }

  Future<List<ExtensionListItem>> search(
    String kw,
    int page, {
    Map<String, List<String>>? filter,
  }) async {
    return runExtension(() async {
      final jsResult = await runtime.handlePromise(
        await runtime.evaluateAsync(Platform.isLinux
            ? 'extension.search("$kw",$page,${filter == null ? null : jsonEncode(filter)})'
            : 'stringify(()=>extension.search("$kw",$page,${filter == null ? null : jsonEncode(filter)}))'),
      );
      List<ExtensionListItem> result =
          jsonDecode(jsResult.stringResult).map<ExtensionListItem>((e) {
        return ExtensionListItem.fromJson(e);
      }).toList();
      for (var element in result) {
        element.headers ??= await _defaultHeaders;
      }
      return result;
    });
  }

  Future<Map<String, ExtensionFilter>> createFilter({
    Map<String, List<String>>? filter,
  }) async {
    late String eval;
    final className = extension.package.replaceAll('.', '');
    if (filter == null) {
      eval = Platform.isLinux
          ? '${className}Instance.createFilter()'
          : 'stringify(()=>extension.createFilter())';
    } else {
      eval = Platform.isLinux
          ? '{className}Instance.createFilter(JSON.parse(\'${jsonEncode(filter)}\'))'
          : 'stringify(()=>extension.createFilter(JSON.parse(\'${jsonEncode(filter)}\')))';
    }
    return runExtension(() async {
      final jsResult = await runtime.handlePromise(
        await runtime.evaluateAsync(eval),
      );
      Map<String, dynamic> result = jsonDecode(jsResult.stringResult);
      return result.map(
        (key, value) => MapEntry(
          key,
          ExtensionFilter.fromJson(value),
        ),
      );
    });
  }

  Future<ExtensionDetail> detail(String url) async {
    return runExtension(() async {
      final jsResult = await runtime.handlePromise(
        await runtime.evaluateAsync(Platform.isLinux
            ? '${className}Instance.detail("$url")'
            : 'stringify(()=>extension.detail("$url"))'),
      );
      final result =
          ExtensionDetail.fromJson(jsonDecode(jsResult.stringResult));
      result.headers ??= await _defaultHeaders;
      return result;
    });
  }

  Future<Object?> watch(String url) async {
    return runExtension(() async {
      final jsResult = await runtime.handlePromise(
        await runtime.evaluateAsync(Platform.isLinux
            ? '${className}Instance.watch("$url")'
            : 'stringify(()=>extension.watch("$url"))'),
      );
      final data = jsonDecode(jsResult.stringResult);

      switch (extension.type) {
        case ExtensionType.bangumi:
          final result = ExtensionBangumiWatch.fromJson(data);
          result.headers ??= await _defaultHeaders;
          return result;
        case ExtensionType.manga:
          final result = ExtensionMangaWatch.fromJson(data);
          result.headers ??= await _defaultHeaders;
          return result;
        default:
          return ExtensionFikushonWatch.fromJson(data);
      }
    });
  }

  Future<String> checkUpdate(url) async {
    return runExtension(() async {
      final jsResult = await runtime.handlePromise(
        await runtime
            .evaluateAsync('stringify(()=>extension.checkUpdate("$url"))'),
      );
      return jsResult.stringResult;
    });
  }
}
