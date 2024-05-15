import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:notes_flutter/firebase/firestore_note_model.dart';
import 'package:notes_flutter/local/note_model.dart';
import 'package:notes_flutter/models/notes_item.dart';
import 'package:notes_flutter/util/async/multiuse_streams.dart';
import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi_web/sqflite_ffi_web.dart';

class DatabaseHelper {
  late Future<Database> _futureDatabase;
  String DATABASE_NAME = "notes_database.db";

  late Sink<List<NoteModel>> _noteSink;

  late Future<List<NoteModel>> _initialNotesList;

  late MultiUseStream<List<NoteModel>> _multiUseStream;

  DatabaseHelper() {
    if (kIsWeb) {
      databaseFactory = databaseFactoryFfiWeb;
      _futureDatabase = _getDatabaseFuture(DATABASE_NAME);
    } else {
      _futureDatabase = getDatabasesPath().then((databasePath) =>
          _getDatabaseFuture(join(databasePath, DATABASE_NAME)));
    }

    _initialNotesList = getNoteList();

    StreamController<List<NoteModel>> controller = StreamController(
      onListen: () {
        print("listening to notes stream");
        _initialNotesList.then((value) {
          print("Initial notes fetched");
          _noteSink.add(value);
        });
      }
    );
    _multiUseStream = MultiUseStream(controller.stream);
    _noteSink = controller.sink;
  }

  Stream<List<NoteModel>> get notesStream => _multiUseStream.stream();

  Future<Database> _getDatabaseFuture(String path) {
    return openDatabase(
      DATABASE_NAME,

      onCreate: (db, version) {
        return db.execute(
          "CREATE TABLE notes(`index` INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, title TEXT NOT NULL, content TEXT NOT NULL, time TEXT NOT NULL, firestoreId TEXT)",
        );
      },

      onUpgrade: (Database db, int oldVersion, int newVersion) {
        print("Upgrading database");
        Future<void>? upgradeFuture;

        chainFuture(Future<void> future) {
          //Initialize upgradeFuture to future if upgradeFuture is null else chain future
          upgradeFuture = upgradeFuture?.then((_) => future) ?? future;
        }

        if (oldVersion < 2 && newVersion >= 2) {
          String currentTime = DateTime.timestamp().toString();
          chainFuture(
            db.execute("ALTER TABLE notes ADD COLUMN time TEXT DEFAULT \"$currentTime\" NOT NULL")
                .then((_) => db.rawUpdate("UPDATE notes SET time = ?", [currentTime])),
          );
        }
        if (oldVersion < 3 && newVersion >= 3) {
          chainFuture(
            db.execute("ALTER TABLE notes ADD COLUMN firestoreId TEXT")
          );
        }

        return upgradeFuture;
      },
      version: 3,
    );
  }

  Future<List<NoteModel>> getNoteList() async {
    Database database = await _futureDatabase;

    List<Map<String, Object?>> noteMapList = await database.query("notes");

    return List<NoteModel>.from(noteMapList.map(NoteModel.fromMap));
  }

  Future<List<NoteModel>> getLocalUpsertList(String lastUpdated) async {
    Database database = await _futureDatabase;

    List<Map<String, Object?>> noteMapList = await database.query(
        "notes",
        where: "time > ?",
        whereArgs: [lastUpdated]
    );

    return noteMapList.map((item) => NoteModel.fromMap(item)).toList();
  }

  Future<int> addNote(NotesItem notesItem, String time) async {
    Database database = await _futureDatabase;
    Map<String, Object?> notesItemMap = notesItem.toMap();
    notesItemMap["time"] = time;

    int index = await database.insert(
      "notes",
      notesItemMap,
      conflictAlgorithm: ConflictAlgorithm.rollback,
    );

    notifyStream();

    return index;
  }

  Future<void> updateNote(NoteModel noteModel) async {
    Database database = await _futureDatabase;

    int count = await database.update(
      "notes",
      noteModel.toMap(),
      where: "`index` = ?",
      whereArgs: [noteModel.index],
      conflictAlgorithm: ConflictAlgorithm.fail,
    );

    notifyStream();

    print("$count rows affected");
  }

  Future<void> upsertAndDeleteFirebaseNotes(List<FirestoreNoteModel> firebaseNotes, List<String> deletedFirestoreIdList) async {
    Database db = await _futureDatabase;

    List<String> allFirestoreIds = firebaseNotes.map((val) => val.documentId).toList();

    //Getting details of rows that need to be updated
    List<Map<String, dynamic>> data = await db.query(
      "notes",
      where: "firestoreId IN (${List.filled(allFirestoreIds.length, "?").join(",")})",
      whereArgs: allFirestoreIds,
    );

    Set<String> existingFirestoreIds = data
        .where((value) => value["firestoreId"] != null)
        .map((value) => value["firestoreId"] as String)
        .toSet();

    List<Object?> results = await db.transaction<List<Object?>>((txn) async {
      Batch batch = txn.batch();
      for (FirestoreNoteModel firebaseNote in firebaseNotes) {
        Map<String,Object?> map = {
          "title": firebaseNote.title,
          "content": firebaseNote.content,
          "time" : firebaseNote.lastUpdated,
        };
        if (existingFirestoreIds.contains(firebaseNote.documentId)) {
          batch.update("notes", map, where: "firestoreId = ?", whereArgs: [firebaseNote.documentId]);
        } else {
          map["firestoreId"] = firebaseNote.documentId;
          batch.insert("notes", map);
        }
      }

      batch.delete(
        "notes",
        where: "firestoreId IN (${List.filled(deletedFirestoreIdList.length, "?").join(",")})",
        whereArgs: deletedFirestoreIdList,
      );
      return await batch.commit();
    });

    notifyStream();
  }

  Future<void> updateNewFirestoreIds(List<int> indices, List<String> firestoreIds) async {
    Database database = await _futureDatabase;
    database.transaction((txn) {
      Batch batch = txn.batch();
      for (int i = 0; i < indices.length; i++) {
        batch.update(
          "notes",
          {"firestoreId": firestoreIds[i]},
          where: "`index` = ?",
          whereArgs: [indices[i]],
        );
      }
      return batch.commit();
    });

    notifyStream();
  }

  Future<void> deleteMultipleNotes(Iterable<int> indices) async {
    Database database = await _futureDatabase;

    await database.delete(
      "notes",
      where: "`index` IN (${List.filled(indices.length, "?").join(",")})",
      whereArgs: List.of(indices),
    );

    notifyStream();
  }

  Future<void> deleteNote(NoteModel noteModel) async {
    Database database = await _futureDatabase;

    await database.delete(
      "notes",
      where: "`index` = ?",
      whereArgs: [noteModel.index],
    );

    notifyStream();
  }

  void notifyStream() async {
    _noteSink.add(await getNoteList());
  }

  void dispose() {
    _multiUseStream.close();
    _futureDatabase.then((database) => database.close());
  }
}
