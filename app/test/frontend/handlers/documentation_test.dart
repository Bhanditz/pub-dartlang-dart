// Copyright (c) 2017, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

import 'package:pub_dartlang_org/dartdoc/backend.dart';
import 'package:pub_dartlang_org/dartdoc/models.dart';
import 'package:pub_dartlang_org/frontend/handlers/documentation.dart';
import 'package:pub_dartlang_org/shared/urls.dart';

import 'package:pub_dartdoc_data/pub_dartdoc_data.dart';

import '../../shared/handlers_test_utils.dart';
import '../../shared/utils.dart';

void main() {
  group('path parsing', () {
    void testUri(String rqPath, String package, [String version, String path]) {
      final p = parseRequestUri(Uri.parse('$siteRoot$rqPath'));
      if (package == null) {
        expect(p, isNull);
      } else {
        expect(p, isNotNull);
        expect(p.package, package);
        expect(p.version, version);
        expect(p.path, path);
      }
    }

    test('/documentation', () {
      testUri('/documentation', null);
    });
    test('/documentation/', () {
      testUri('/documentation/', null);
    });
    test('/documentation/angular', () {
      testUri('/documentation/angular', 'angular');
    });
    test('/documentation/angular/', () {
      testUri('/documentation/angular/', 'angular');
    });
    test('/documentation/angular/4.0.0+2', () {
      testUri('/documentation/angular/4.0.0+2', 'angular', '4.0.0+2');
    });
    test('/documentation/angular/4.0.0+2/', () {
      testUri('/documentation/angular/4.0.0+2/', 'angular', '4.0.0+2',
          'index.html');
    });
    test('/documentation/angular/4.0.0+2/subdir/', () {
      testUri('/documentation/angular/4.0.0+2/subdir/', 'angular', '4.0.0+2',
          'subdir/index.html');
    });
    test('/documentation/angular/4.0.0+2/file.html', () {
      testUri('/documentation/angular/4.0.0+2/file.html', 'angular', '4.0.0+2',
          'file.html');
    });
    test('/documentation/angular/4.0.0+2/file.html', () {
      testUri('/documentation/angular/4.0.0+2/file.html', 'angular', '4.0.0+2',
          'file.html');
    });
  });

  group('dartdoc handlers', () {
    Future<shelf.Response> issueGet(String uri) => documentationHandler(
        shelf.Request('GET', Uri.parse('https://pub.dartlang.org$uri')));

    test('/documentation/flutter redirect', () async {
      expectRedirectResponse(
        await issueGet('/documentation/flutter'),
        'https://docs.flutter.io/',
      );
    });

    test('/documentation/flutter/version redirect', () async {
      expectRedirectResponse(
        await issueGet('/documentation/flutter/version'),
        'https://docs.flutter.io/',
      );
    });

    test('/documentation/foo/bar redirect', () async {
      expectRedirectResponse(
        await issueGet('/documentation/foor/bar'),
        'https://pub.dartlang.org/documentation/foor/bar/',
      );
    });

    scopedTest('trailing slash redirect', () async {
      expectRedirectResponse(
          await issueGet('/documentation/foo'), '/documentation/foo/latest/');
    });

    scopedTest('/documentation/no_pkg redirect', () async {
      registerDartdocBackend(DartdocBackendMock());
      expectRedirectResponse(await issueGet('/documentation/no_pkg/latest/'),
          '/packages/no_pkg/versions');
    });
  });
}

class DartdocBackendMock implements DartdocBackend {
  final List<DartdocEntry> entries;
  final Map<String, String> latestVersions;

  DartdocBackendMock({this.entries, this.latestVersions});

  @override
  Future<FileInfo> getFileInfo(DartdocEntry entry, String relativePath) {
    throw UnimplementedError();
  }

  @override
  Future<DartdocEntry> getServingEntry(String package, String version) async {
    return entries?.lastWhere(
      (entry) =>
          entry.packageName == package &&
          entry.packageVersion == version &&
          entry.isServing,
      orElse: () => null,
    );
  }

  @override
  Future<DartdocEntry> getLatestEntry(String package, String version) async {
    return entries?.lastWhere(
      (entry) =>
          entry.packageName == package && entry.packageVersion == version,
      orElse: () => null,
    );
  }

  @override
  Future<String> getLatestVersion(String package) async {
    if (latestVersions == null) return null;
    return latestVersions[package];
  }

  @override
  Future<List<String>> getLatestVersions(String package,
      {int limit = 10}) async {
    if (latestVersions == null) return <String>[];
    final v = latestVersions[package];
    if (v == null) return <String>[];
    return <String>[v];
  }

  @override
  Stream<List<int>> readContent(DartdocEntry entry, String relativePath) {
    throw UnimplementedError();
  }

  @override
  Future removeAll(String package, {String version, int concurrency}) {
    throw UnimplementedError();
  }

  @override
  Future removeObsolete(String package, String version) {
    throw UnimplementedError();
  }

  @override
  Future uploadDir(DartdocEntry entry, String dirPath) {
    throw UnimplementedError();
  }

  @override
  Future<bool> hasValidDartSdkDartdocData() {
    throw UnimplementedError();
  }

  @override
  Future<PubDartdocData> getDartSdkDartdocData() {
    throw UnimplementedError();
  }

  @override
  Future uploadDartSdkDartdocData(File file) {
    throw UnimplementedError();
  }

  @override
  void scheduleOldDataGC() {
    throw UnimplementedError();
  }

  @override
  Future<String> getTextContent(DartdocEntry entry, String relativePath) {
    throw UnimplementedError();
  }

  @override
  Future updateOldEntry(DartdocEntry old, DartdocEntry current) {
    throw UnimplementedError();
  }
}
