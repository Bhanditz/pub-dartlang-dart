// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library pub_dartlang_org.backend;

import 'dart:async';
import 'dart:io';

import 'package:gcloud/db.dart';
import 'package:gcloud/storage.dart';
import 'package:gcloud/service_scope.dart' as ss;
import 'package:pub_server/repository.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

import 'models.dart' as models;
import 'model_properties.dart';
import 'upload_signer_service.dart';
import 'utils.dart';

final Logger _logger = new Logger('pub.cloud_repository');


/// Sets the active logged-in user.
void registerLoggedInUser(String user) => ss.register(#_logged_in_user, user);

/// The active logged-in user. This is used for doing authentication checks.
String get loggedInUser => ss.lookup(#_logged_in_user);


/// Sets the active tarball storage
void registerTarballStorage(TarballStorage ts)
    => ss.register(#_tarball_storage, ts);

/// The active tarball storage.
TarballStorage get tarballStorage => ss.lookup(#_tarball_storage);


/// Sets the backend service.
void registerBackend(Backend backend) => ss.register(#_backend, backend);

/// The active backend service.
Backend get backend => ss.lookup(#_backend);


/// Represents the backend for the pub.dartlang.org site.
class Backend {
  final DatastoreDB db;
  final GCloudPackageRepository repository;

  Backend(DatastoreDB db, TarballStorage storage)
      : db = db, repository = new GCloudPackageRepository(db, storage);

  /// Retrieves packages ordered by their latest version date.
  Future<List<models.Package>> latestPackages(
      {int offset: null, int limit: null}) {
    var query = db.query(models.Package)
        ..order('-updated')
        ..offset(offset)
        ..limit(limit);
    return query.run().toList();
  }

  /// Retrieves package versions ordered by their latest version date.
  Future<List<models.PackageVersion>> latestPackageVersions(
      {int offset: null, int limit: null}) async {
    var packages = await latestPackages(offset: offset, limit: limit);
    return lookupLatestVersions(packages);
  }

  /// Looks up a package by name.
  Future<models.Package> lookupPackage(String packageName) async {
    var packageKey = db.emptyKey.append(models.Package, id: packageName);
    return (await db.lookup([packageKey])).first;
  }

  /// Looks up a specific package version.
  Future<models.Package> lookupPackageVersion(String package,
                                              String version) async {
    var packageVersionKey = db.emptyKey
        .append(models.Package, id: package)
        .append(models.PackageVersion, id: version);
    return (await db.lookup([packageVersionKey])).first;
  }

  /// Looks up the latest versions of a list of packages.
  Future<List<models.PackageVersion>> lookupLatestVersions(
      List<models.Package> packages) {
    var keys = packages.map((models.Package p) => p.latestVersionKey).toList();
    return db.lookup(keys);
  }

  /// Looks up all versions of a package.
  Future<List<models.PackageVersion>> versionsOfPackage(String packageName) {
    var packageKey = db.emptyKey.append(models.Package, id: packageName);
    var query = db.query(models.PackageVersion, ancestorKey: packageKey);
    return query.run().toList();
  }

  /// Get a [Uri] which can be used to download a tarball of the pub package.
  Future<Uri> downloadUrl(String package, String version) {
    assert (repository.supportsDownloadUrl);
    return repository.downloadUrl(package, version);
  }
}


/// A read-only implementation of [PackageRepository] using the Cloud Datastore
/// for metadata and Cloud Storage for tarball storage.
class GCloudPackageRepository extends PackageRepository {
  static const int MAX_TARBALL_SIZE = 10 * 1024  * 1024;

  final Uuid uuid = new Uuid();
  final DatastoreDB db;
  final TarballStorage storage;

  GCloudPackageRepository(this.db, this.storage);

  // Metadata support.

  Stream<PackageVersion> versions(String package) {
    var controller;
    var subscription;

    controller = new StreamController(
        onListen: () {
          var packageKey = db.emptyKey.append(models.Package, id: package);
          var query = db.query(models.PackageVersion, ancestorKey: packageKey);
          subscription = query.run().listen((models.PackageVersion model) {
            var packageVersion = new PackageVersion(
                package, model.version, model.pubspec.jsonString);
            controller.add(packageVersion);
          }, onError: (error, stack) => controller.addError(error, stack),
             onDone: () => controller.close());
        },
        onPause: () => subscription.pause(),
        onResume: () => subscription.resume(),
        onCancel: () => subscription.cancel());
    return controller.stream;
  }

  Future<PackageVersion> lookupVersion(String package, String version) async {
    var packageVersionKey = db
        .emptyKey
        .append(models.Package, id: package)
        .append(models.PackageVersion, id: version);

    models.PackageVersion pv = (await db.lookup([packageVersionKey])).first;
    if (pv == null) return null;
    return new PackageVersion(package, version, pv.pubspec.jsonString);
  }

  // Download support.

  Future<Stream<List<int>>> download(String package, String version) {
    // TODO: Should we first test for existence?
    // Maybe with a cache?
    return new Future.value(storage.download(package, version));
  }

  bool get supportsDownloadUrl => true;

  Future<Uri> downloadUrl(String package, String version) {
    return storage.downloadUrl(package, version);
  }

  // Upload support.

  bool get supportsUpload => true;

  Future<PackageVersion> upload(Stream<List<int>> data)  {
    _logger.info('Starting upload.');
    return withAuthenticatedUser((String userEmail) {
      _logger.info('User: $userEmail.');

      // Read the entire tarball & keep it in memory (fail if > 10 MB).
      // TODO: Find out why we it times out when we do it in an async scope.
      // TODO: Try avoid keeping everything in memory and try streaming it
      // to disc instead.
      return readTarball(data).then((List<int> tarball) {
        return _performTarballUpload(userEmail, tarball, (package, version) {
          return storage.upload(package, version, tarball);
        });
      });
    });
  }

  bool get supportsAsyncUpload => true;

  Future<AsyncUploadInfo> startAsyncUpload(Uri redirectUrl) async {
    _logger.info('Starting async upload.');
    // NOTE: We use a authenticated user scope here to ensure the uploading
    // user is authenticated. But we're not validating anything at this point
    // because we don't even know which package or version is going to be
    // uploaded.
    return withAuthenticatedUser((String userEmail) {
      _logger.info('User: $userEmail.');

      String guid =  uuid.v4();
      String object = storage.tempObjectName(guid);
      String bucket = storage.bucket.bucketName;
      Duration lifetime = const Duration(minutes: 10);

      var url = redirectUrl.resolve('?upload_id=$guid');

      _logger.info(
          'Redirecting pub client to google cloud storage (uuid: $guid)');
      return uploadSigner.buildUpload(bucket, object, lifetime, '$url');
    });
  }

  /// Finishes the upload of a package.
  Future<PackageVersion> finishAsyncUpload(Uri uri) {
    return withAuthenticatedUser((String userEmail) async {
      var guid = uri.queryParameters['upload_id'];
      _logger.info('Finishing async upload (uuid: $guid)');
      _logger.info('Reading tarball from cloud storage.');
      // TODO: Try avoid keeping everything in memory and try streaming it
      // to disc instead.
      var tarball = await readTarball(storage.readTempObject(guid));
      return _performTarballUpload(userEmail, tarball, (package, version) {
        return storage.uploadViaTempObject(guid, package, version);
      }).whenComplete(() async {
        _logger.info('Removing temporary object $guid.');
        await storage.removeTempObject(guid);
      });
    });
  }

  Future<PackageVersion> _performTarballUpload(
      String userEmail, List<int> tarball,
      Future tarballUpload(name, version)) async {
      _logger.info('Examining tarball content.');

    // Parse metadata from the tarball.
    models.PackageVersion newVersion =
        await parseAndValidateUpload(db, tarball, userEmail);

    // Add the new package to the repository by storing the tarball and
    // inserting metadata to datastore (which happens atomically).
    return await db.withTransaction((Transaction T) async {
      _logger.info('Starting datastore transaction.');

      var tuple = (await T.lookup([newVersion.key, newVersion.packageKey]));
      models.PackageVersion version = tuple[0];
      models.Package package = tuple[1];

      // If the version already exists, we fail.
      if (version != null) {
        await T.rollback();
        _logger.warning('Version already exists, rolling transaction back.');
        throw 'version already exists';
      }

      // If the package does not exist, then we create a new package.
      if (package == null) package = newPackageFromVersion(db, newVersion);

      // Check if the uploader of the new version is allowed to upload to
      // the package.
      if (!package.uploaderEmails.contains(newVersion.uploaderEmail)) {
        _logger.warning('User is not an uploader, rolling transaction back.');
        await T.rollback();
        throw new UnauthorizedAccessException('Unauthorized user.');
      }

      // Update the date when the package was last updated.
      package.updated = newVersion.created;

      // Keep the latest version in the package object up-to-date.
      if (package.latestSemanticVersion < newVersion.semanticVersion &&
          (package.latestSemanticVersion.isPreRelease ||
           !newVersion.semanticVersion.isPreRelease)) {
        package.latestVersionKey = newVersion.key;
      }

      try {
        _logger.info('Trying to upload tarball to cloud storage.');
        // Apply update: Push to cloud storage
        await tarballUpload(package.name, newVersion.version);

        // Apply update: Update datastore.
        _logger.info('Trying to commit datastore changes.');
        T.queueMutations(inserts: [package, newVersion]);
        await T.commit();

        _logger.info('Upload successful.');

        // Defer the creation of sort_order
        // TODO:

        return new PackageVersion(
            newVersion.package, newVersion.version,
            newVersion.pubspec.jsonString);
      } catch (error, stack) {
        _logger.warning('Error while committing: $error, $stack');
        await T.rollback();
        rethrow;
      }
    });
  }

  // Uploaders support.

  bool get supportsUploaders => true;

  Future addUploader(String packageName, String uploaderEmail) async {
    return withAuthenticatedUser((String userEmail) {
      return db.withTransaction((Transaction T) async {
        var packageKey = db.emptyKey.append(models.Package, id: packageName);
        models.Package package = (await T.lookup([packageKey])).first;

        // Fail if package doesn't exist.
        if (package == null) {
          await T.rollback();
          throw new Exception('Package "$package" does not exist');
        }


        // Fail if calling user doesn't have permission to change uploaders.
        if (!package.uploaderEmails.contains(userEmail)) {
          await T.rollback();
          throw new UnauthorizedAccessException(
              'Calling user does not have permission to change uploaders.');
        }

        // Fail if the uploader we want to add already exists.
        if (package.uploaderEmails.contains(uploaderEmail)) {
          await T.rollback();
          throw new UploaderAlreadyExistsException();
        }

        // Add [uploaderEmail] to uploaders and commit.
        package.uploaderEmails.add(uploaderEmail);
        T.queueMutations(inserts: [package]);
        return T.commit();
      });
    });
  }

  Future removeUploader(String packageName, String uploaderEmail) async {
    return withAuthenticatedUser((String userEmail) {
      return db.withTransaction((Transaction T) async {
        var packageKey = db.emptyKey.append(models.Package, id: packageName);
        models.Package package = (await T.lookup([packageKey])).first;

        // Fail if package doesn't exist.
        if (package == null) {
          await T.rollback();
          throw new Exception('Package "$package" does not exist');
        }


        // Fail if calling user doesn't have permission to change uploaders.
        if (!package.uploaderEmails.contains(userEmail)) {
          await T.rollback();
          throw new UnauthorizedAccessException(
              'Calling user does not have permission to change uploaders.');
        }

        // Fail if the uploader we want to remove does not exist.
        if (!package.uploaderEmails.contains(uploaderEmail)) {
          await T.rollback();
          throw new Exception('The uploader to remove does not exist.');
        }

        package.uploaderEmails = package
            .uploaderEmails.where((email) => email != uploaderEmail).toList();

        // We cannot have 0 uploaders, if we would remove the last one, we
        // fail with an error.
        if (package.uploaderEmails.isEmpty) {
          await T.rollback();
          throw new LastUploaderRemoveException();
        }

        T.queueMutations(inserts: [package]);
        return T.commit();
      });
    });
  }
}

/// Calls [func] with the currently logged in user as an argument.
///
/// If no user is currently logged in, this will throw an `UnauthorizedAccess`
/// exception.
withAuthenticatedUser(func(String user)) async {
  if (loggedInUser == null) {
    throw new UnauthorizedAccessException('No active user.');
  }
  return func(loggedInUser);
}

/// Reads a tarball from a byte stream.
///
/// Compeltes with an error if the incoming stream has an error or if the size
/// exceeds `GcloudPackageRepo.MAX_TARBALL_SIZE`.
Future<List<int>> readTarball(Stream<List<int>> data) {
  var tarballBytes = new BytesBuilder();
  var subscription;
  var completer = new Completer();

  subscription = data.listen((List<int> chunk) {
    tarballBytes.add(chunk);
    if (tarballBytes.length > GCloudPackageRepository.MAX_TARBALL_SIZE) {
      // TODO: Test that this actually results in a shutdown() of the socket
      // so we don't buffer data.
      subscription.cancel();
      completer.completeError(
          'Invalid upload: Exceeded ${GCloudPackageRepository.MAX_TARBALL_SIZE} '
          'upload size.');
    }
  }, onError: (error, stack) {
    subscription.cancel();
    completer.completeError(error, stack);
  }, onDone: () {
    completer.complete(tarballBytes.takeBytes());
  });

  return completer.future;
}

/// Creates a new `Package` and populates all of it's fields.
models.Package newPackageFromVersion(DatastoreDB db,
                                     models.PackageVersion version) {
  var now = new DateTime.now().toUtc();
  return new models.Package()
      ..parentKey = db.emptyKey
      ..id = version.pubspec.name
      ..name = version.pubspec.name
      ..created = now
      ..updated = now
      ..downloads = 0
      ..latestVersionKey = version.key
      ..uploaderEmails = [loggedInUser];
}

/// Parses metadata from a tarball and & validates it.
///
/// This function ensures that `tarball`
///   * is a valid `tar.gz` file
///   * contains a valid `pubspec.yaml` file
///   * reads readme, changelog and pubspec files
///   * creates a [models.PackageVersion] and populates it with all metadata
Future<models.PackageVersion> parseAndValidateUpload(DatastoreDB db,
                                                     List<int> tarball,
                                                     String user) async {
  assert (user != null);

  return withTempDirectory((Directory dir) async {
    // TODO: We could think about streaming this to a file instead of doing
    // synchronous writing.
    var file = new File('data.bin');
    await file.writeAsBytes(tarball);

    var files = await listTarball(file.path);

    var readmeFilename;
    if (files.contains('README.md')) readmeFilename = 'README.md';
    else if (files.contains('README')) readmeFilename = 'README';

    var changelogFilename;
    if (files.contains('CHANGELOG.md')) changelogFilename = 'CHANGELOG.md';
    else if (files.contains('CHANGELOG')) readmeFilename = 'CHANGELOG';

    var libraries = files
        .where((file) => file.startsWith('lib/'))
        .where((file) => !file.startsWith('lib/src'))
        .where((file) => file.endsWith('.dart'))
        .map((file) => file.substring('lib/'.length))
        .toList();

    if (!files.contains('pubspec.yaml')) {
      throw 'Invalid upload: no pubspec.yaml file';
    }

    var pubspecContent = await readTarballFile(file.path, 'pubspec.yaml');

    var pubspec = new Pubspec.fromYaml(pubspecContent);
    if (pubspec.name == null || pubspec.version == null) {
      throw 'Invalid `pubspec.yaml` file';
    }

    var readmeContent = readmeFilename != null
        ? await readTarballFile(file.path, readmeFilename) : null;
    var changelogContent = changelogFilename != null
        ? await readTarballFile(file.path, changelogFilename) : null;

    var packageKey = db.emptyKey.append(models.Package, id: pubspec.name);

    var version = new models.PackageVersion()
        ..id = pubspec.version
        ..parentKey = packageKey
        ..version = pubspec.version
        ..packageKey = packageKey
        ..created = new DateTime.now().toUtc()
        ..pubspec = pubspec
        ..readmeFilename = readmeFilename
        ..readmeContent = readmeContent
        ..changelogFilename = changelogFilename
        ..changelogContent = changelogContent
        ..libraries = libraries
        ..downloads = 0
        ..sortOrder = 1
        ..uploaderEmail = user;
    return version;
  });
}

/// Helper utility class for interfacing with Cloud Storage for storing
/// tarballs.
class TarballStorage {
  final TarballStorageNamer namer;
  final Storage storage;
  final Bucket bucket;

  TarballStorage(this.storage, Bucket bucket, String namespace) :
      bucket = bucket,
      namer = new TarballStorageNamer(bucket.bucketName, namespace);

  /// Generates a path to a temporary object on cloud storage.
  String tempObjectName(String guid) => namer.tmpObjectName(guid);

  /// Reads the temporary object identified by [guid]
  Stream<List<int>> readTempObject(String guid)
      => bucket.read(namer.tmpObjectName(guid));

  /// Makes a temporary object a new tarball.
  Future uploadViaTempObject(String guid,
                             String package,
                             String version) async {
    var object = namer.tarballObjectName(package, version);

    // Copy the temporary object to it's destination place.
    await storage.copyObject(
        bucket.absoluteObjectName(namer.tmpObjectName(guid)),
        bucket.absoluteObjectName(object));

    // Change the ACL to include a `public-read` entry.
    ObjectInfo info = await bucket.info(object);
    var publicRead = new AclEntry(new AllUsersScope(), AclPermission.READ);
    var acl =
        new Acl(new List.from(info.metadata.acl.entries)..add(publicRead));
    await bucket.updateMetadata(object, info.metadata.replace(acl: acl));
  }

  /// Remove a previously generated temporary object.
  Future removeTempObject(String guid) async {
    if (guid == null) throw new ArgumentError('No guid given.');
    return bucket.delete(namer.tmpObjectName(guid));
  }

  /// Download the tarball of a [package] in the given [version].
  Stream<List<int>> download(String package, String version) {
    var object = namer.tarballObjectName(package, version);
    return bucket.read(object);
  }

  /// Get the URL to the tarball of a [package] in the given [version].
  Future<Uri> downloadUrl(String package, String version) {
    // NOTE: We should maybe check for existence first?
    // return storage.bucket(bucket).info(object)
    //     .then((info) => info.downloadLink);
    return new Future.value(
        Uri.parse(namer.tarballObjectUrl(package, version)));
  }

  /// Upload [tarball] of a [package] in the given [version].
  Future upload(String package, String version, List<int> tarball) {
    var object = namer.tarballObjectName(package, version);
    return bucket.writeBytes(
        object, tarball, predefinedAcl: PredefinedAcl.publicRead);
  }

}

/// Class used for getting GCS object/bucket names and object URLs.
///
///
/// The GCS bucket contains package tarballs in a temporary place and stored
/// package tarballs which are used by clients. The latter can be stored either
/// via an empty or non-empty namespace.
///
/// The layout of the GCS bucket is as follows:
///   gs://<bucket-name>/tmp/<uuid>
///   gs://<bucket-name>/packages/<package-name>-<version>.tar.gz
///   gs://<bucket-name>/ns/<namespace>/packages/<package-name>-<version>.tar.gz
class TarballStorageNamer {
  /// The GCS bucket used.
  final String bucket;

  /// The namespace used.
  final String namespace;

  /// The prefix of where packages are stored (i.e. '' or 'ns/<namespace>').
  final String prefix;

  TarballStorageNamer(this.bucket, String namespace) :
      namespace = namespace == null ? '' : namespace,
      prefix = (namespace == null || namespace.isEmpty) ? '' : 'ns/$namespace/';

  /// The GCS object name of a tarball object - excluding leading '/'.
  String tarballObjectName(String package, String version)
      // TODO: Do we need some kind of escaping here?
      => '${prefix}packages/$package-$version.tar.gz';

  /// The GCS object name of an temporary object [guid] - excluding leading '/'.
  String tmpObjectName(String guid) => 'tmp/$guid';

  /// The http URL of a publicly accessable GCS object.
  String tarballObjectUrl(String package, String version) {
    var object = tarballObjectName(package, version);
    return 'https://storage.googleapis.com/${bucket}/${object}';
  }
}