import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

/// Base local del teléfono y sincronización con el servidor.
///
/// Todo se guarda primero aquí (SQLite), así que la app funciona sin señal. Lo que falta por subir queda en
/// cola con estado "pendiente"; al recuperar conexión se envía solo. Si alguien cambió la misma visita en el
/// servidor, queda en "conflicto" y la persona elige cuál versión conservar.
class Datos {
  Datos._();
  static final Datos yo = Datos._();

  late Database _db;
  late SharedPreferences _prefs;
  Timer? _reloj;
  bool _ocupado = false;

  /// Estado de la sincronización, para el indicador de la pantalla.
  final estado = ValueNotifier<EstadoSync>(const EstadoSync());

  Future<void> abrir() async {
    _prefs = await SharedPreferences.getInstance();
    _db = await openDatabase(
      p.join(await getDatabasesPath(), 'psa_campo.db'),
      version: 2,
      onUpgrade: (db, viejo, _) async {
        if (viejo < 2) await _crearCola(db);
      },
      onCreate: (db, _) async {
        await _crearCola(db);
        await db.execute('create table predios (id text primary key, nombre text, json text not null)');
        await db.execute('create table visitas (id text primary key, predio_id text not null, fecha text not null, json text not null, '
            "revision_base integer not null default 0, estado text not null default 'pendiente', motivo text, servidor text)");
        await db.execute('create table fotos (id text primary key, visita_id text not null, ruta text not null, lat real, lon real, '
            'tomada_en text not null, descripcion text, subida integer not null default 0)');
      },
    );
    await _refrescarEstado();
    // Reintenta sola cada minuto; sin señal simplemente falla y espera al siguiente intento.
    _reloj ??= Timer.periodic(const Duration(minutes: 1), (_) => sincronizar());
  }

  /// Cola de cambios hechos en el teléfono que no son visitas: predios nuevos y polígonos delimitados.
  static Future<void> _crearCola(Database db) => db.execute(
      "create table cola (id text primary key, tipo text not null, predio_id text not null, json text not null, estado text not null default 'pendiente', motivo text, creado text not null)");

  // ---------- Sesión ----------

  /// Dirección de la plataforma en internet; se fija al compilar con --dart-define=SERVIDOR=https://…
  static const servidorPorDefecto = String.fromEnvironment('SERVIDOR');
  String get servidor => _prefs.getString('servidor') ?? servidorPorDefecto;

  /// Acepta la dirección como la escriba la persona: sin "https://", con espacios o con "/" al final.
  static String normalizar(String direccion) {
    var d = direccion.trim().replaceAll(RegExp(r'/+$'), '');
    if (d.isNotEmpty && !RegExp(r'^https?://', caseSensitive: false).hasMatch(d)) {
      // Una dirección de la red local (números o "localhost") va sin cifrar; cualquier otra, por https.
      d = (RegExp(r'^(d{1,3}.){3}d{1,3}(:d+)?$').hasMatch(d) || d.startsWith('localhost') ? 'http://' : 'https://') + d;
    }
    return d;
  }
  String? get token => _prefs.getString('token');
  String get usuario => _prefs.getString('usuario') ?? '';

  /// Correo con el que se ingresó: identifica a quien registra cada visita.
  String get correo => _prefs.getString('correo') ?? '';
  String get dispositivo {
    var id = _prefs.getString('dispositivo');
    if (id == null) {
      id = const Uuid().v4();
      _prefs.setString('dispositivo', id);
    }
    return id;
  }

  /// Devuelve null si entró, o el mensaje de error.
  Future<String?> ingresar(String servidor, String correo, String clave) async {
    final base = normalizar(servidor);
    if (base.isEmpty) return 'Escribe la dirección del servidor.';
    try {
      final r = await http
          .post(Uri.parse('$base/api/movil/ingresar'), headers: {'content-type': 'application/json'}, body: jsonEncode({'correo': correo.trim(), 'clave': clave}))
          .timeout(const Duration(seconds: 120)); // el servidor en la nube puede estar dormido y tarda en despertar
      final cuerpo = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
      if (r.statusCode != 200) return cuerpo['error'] as String? ?? 'No se pudo ingresar.';
      await _prefs.setString('servidor', base);
      await _prefs.setString('token', cuerpo['token'] as String);
      await _prefs.setString('usuario', (cuerpo['usuario'] as Map)['nombre'] as String);
      await _prefs.setString('correo', ((cuerpo['usuario'] as Map)['correo'] as String?) ?? correo.trim().toLowerCase());
      await sincronizar();
      return null;
    } on TimeoutException {
      return 'El servidor no respondió. Si llevaba días sin usarse puede estar encendiéndose: espera un minuto y vuelve a intentar.';
    } catch (_) {
      return 'No hay conexión con el servidor. El primer ingreso necesita internet.';
    }
  }

  /// Cosas guardadas en el teléfono que aún no llegan a la plataforma.
  Future<int> sinSubir() async {
    final c = (await _db.rawQuery("select (select count(*) from visitas where estado <> 'sincronizada') + (select count(*) from fotos where subida = 0) + (select count(*) from cola) as n")).first;
    return c['n'] as int;
  }

  /// Cierra la sesión y quita del teléfono los predios, visitas y fotos de esta cuenta, para que quien entre con
  /// otro correo empiece limpio.
  Future<void> salir() async {
    await _prefs.remove('token');
    await _prefs.remove('usuario');
    await _prefs.remove('correo');
    for (final f in await _db.query('fotos')) {
      try {
        await File(f['ruta'] as String).delete();
      } catch (_) {}
    }
    await _db.delete('fotos');
    await _db.delete('visitas');
    await _db.delete('predios');
    await _db.delete('cola');
    await _refrescarEstado();
  }

  // ---------- Lectura ----------

  Future<List<Map<String, dynamic>>> predios() async =>
      (await _db.query('predios', orderBy: 'nombre')).map((f) => jsonDecode(f['json'] as String) as Map<String, dynamic>).toList();

  Future<List<Visita>> visitas({String? predioId}) async {
    final filas = await _db.query('visitas', where: predioId == null ? null : 'predio_id = ?', whereArgs: predioId == null ? null : [predioId], orderBy: 'fecha desc');
    return filas.map(Visita.deFila).toList();
  }

  /// Predios nuevos y polígonos que la plataforma no aceptó, con el motivo.
  Future<List<Map<String, Object?>>> colaConProblema() => _db.query('cola', where: "estado = 'rechazada'", orderBy: 'creado');

  /// Predios con un alta o un polígono todavía por subir.
  Future<Set<String>> prediosPorSubir() async => (await _db.query('cola', columns: ['predio_id'])).map((f) => f['predio_id'] as String).toSet();

  Future<List<Map<String, Object?>>> fotos(String visitaId) => _db.query('fotos', where: 'visita_id = ?', whereArgs: [visitaId], orderBy: 'tomada_en');

  // ---------- Escritura (siempre local primero) ----------

  Future<void> guardarVisita(Visita v) async {
    await _db.insert(
      'visitas',
      {'id': v.id, 'predio_id': v.datos['predio_id'], 'fecha': v.datos['fecha_hora'], 'json': jsonEncode(v.datos), 'revision_base': v.revisionBase, 'estado': 'pendiente', 'motivo': null, 'servidor': null},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await _refrescarEstado();
    unawaited(sincronizar());
  }

  /// Predio nuevo levantado en campo: queda en el teléfono y en cola para subir.
  Future<Map<String, dynamic>> crearPredio(Map<String, dynamic> datos) async {
    final id = const Uuid().v4();
    final predio = <String, dynamic>{...datos, 'id': id, 'titulares': <Object>[], 'acuerdos': <Object>[], 'creado_en_campo': true};
    final ahora = DateTime.now().toUtc().toIso8601String();
    await _db.insert('predios', {'id': id, 'nombre': predio['nombre'], 'json': jsonEncode(predio)});
    await _db.insert('cola', {'id': 'predio-$id', 'tipo': 'predio', 'predio_id': id, 'json': jsonEncode(predio), 'creado': ahora});
    await _refrescarEstado();
    unawaited(sincronizar());
    return predio;
  }

  /// Polígono delimitado en el mapa del teléfono (GeoJSON Polygon). Reemplaza al que tenía el predio.
  Future<void> guardarPoligono(String predioId, Map<String, dynamic> poligono) async {
    final fila = await _db.query('predios', where: 'id = ?', whereArgs: [predioId]);
    if (fila.isNotEmpty) {
      final pr = jsonDecode(fila.first['json'] as String) as Map<String, dynamic>;
      pr['poligono'] = poligono;
      await _db.update('predios', {'json': jsonEncode(pr)}, where: 'id = ?', whereArgs: [predioId]);
    }
    // Si el predio aún no ha subido, el polígono viaja con él.
    final alta = await _db.query('cola', where: "id = ? and estado = 'pendiente'", whereArgs: ['predio-$predioId']);
    if (alta.isNotEmpty) {
      final d = jsonDecode(alta.first['json'] as String) as Map<String, dynamic>;
      d['poligono'] = poligono;
      await _db.update('cola', {'json': jsonEncode(d)}, where: 'id = ?', whereArgs: ['predio-$predioId']);
    } else {
      await _db.insert(
          'cola',
          {'id': 'poligono-$predioId', 'tipo': 'poligono', 'predio_id': predioId, 'json': jsonEncode({'predio_id': predioId, 'poligono': poligono}), 'estado': 'pendiente', 'motivo': null, 'creado': DateTime.now().toUtc().toIso8601String()},
          conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await _refrescarEstado();
    unawaited(sincronizar());
  }

  /// Vuelve a intentar un predio o polígono que la plataforma no aceptó.
  Future<void> reintentarCola(String id) async {
    await _db.update('cola', {'estado': 'pendiente', 'motivo': null}, where: 'id = ?', whereArgs: [id]);
    await _refrescarEstado();
    unawaited(sincronizar());
  }

  /// Descarta un predio o polígono rechazado (el predio nuevo se quita del teléfono).
  Future<void> descartarCola(String id) async {
    final f = await _db.query('cola', where: 'id = ?', whereArgs: [id]);
    if (f.isNotEmpty && f.first['tipo'] == 'predio') await _db.delete('predios', where: 'id = ?', whereArgs: [f.first['predio_id']]);
    await _db.delete('cola', where: 'id = ?', whereArgs: [id]);
    await _refrescarEstado();
  }

  Future<void> agregarFoto(String visitaId, String ruta, double? lat, double? lon, String? descripcion) async {
    await _db.insert('fotos', {'id': const Uuid().v4(), 'visita_id': visitaId, 'ruta': ruta, 'lat': lat, 'lon': lon, 'tomada_en': DateTime.now().toUtc().toIso8601String(), 'descripcion': descripcion});
    await _refrescarEstado();
  }

  /// Resuelve un conflicto: conservar la versión del teléfono (se reenvía forzada) o aceptar la del servidor.
  Future<void> resolverConflicto(Visita v, {required bool conservarMia}) async {
    if (conservarMia) {
      await _db.update('visitas', {'estado': 'pendiente', 'json': jsonEncode({...v.datos, 'forzar': true})}, where: 'id = ?', whereArgs: [v.id]);
    } else {
      final s = v.servidor!;
      await _db.update('visitas', {'estado': 'sincronizada', 'json': jsonEncode(s), 'revision_base': s['revision'] ?? 0, 'servidor': null}, where: 'id = ?', whereArgs: [v.id]);
    }
    await _refrescarEstado();
    unawaited(sincronizar());
  }

  // ---------- Sincronización ----------

  Future<void> _refrescarEstado({bool? sinConexion, bool enCurso = false, String? error}) async {
    final c = (await _db.rawQuery("select (select count(*) from visitas where estado = 'pendiente') as v, (select count(*) from fotos where subida = 0 and visita_id in (select id from visitas)) as f, "
            "(select count(*) from visitas where estado in ('conflicto', 'rechazada')) as x, (select count(*) from cola where estado = 'pendiente') as c, (select count(*) from cola where estado = 'rechazada') as cr"))
        .first;
    estado.value = EstadoSync(
      pendientes: (c['v'] as int) + (c['f'] as int) + (c['c'] as int),
      conProblema: (c['x'] as int) + (c['cr'] as int),
      enCurso: enCurso,
      sinConexion: sinConexion ?? estado.value.sinConexion,
      ultima: _prefs.getString('ultima_sync'),
      error: error,
    );
  }

  Map<String, String> get _auth => {'authorization': 'Bearer $token'};

  Future<void> sincronizar() async {
    if (_ocupado || token == null) return;
    _ocupado = true;
    await _refrescarEstado(enCurso: true);
    try {
      // 0. Predios nuevos (antes que sus visitas) y polígonos delimitados en el teléfono
      for (final fila in await _db.rawQuery("select * from cola where estado = 'pendiente' order by case tipo when 'predio' then 0 else 1 end, creado")) {
        final ruta = fila['tipo'] == 'predio' ? 'predios' : 'poligono';
        final r = await http.post(Uri.parse('$servidor/api/movil/$ruta'), headers: {..._auth, 'content-type': 'application/json'}, body: fila['json'] as String).timeout(const Duration(seconds: 60));
        if (r.statusCode == 401) throw _SesionVencida();
        if (r.statusCode == 200) {
          await _db.delete('cola', where: 'id = ?', whereArgs: [fila['id']]);
        } else if (r.statusCode == 422 || r.statusCode == 400) {
          final resp = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
          await _db.update('cola', {'estado': 'rechazada', 'motivo': resp['error'] ?? 'La plataforma no lo aceptó.'}, where: 'id = ?', whereArgs: [fila['id']]);
        }
      }
      // 1. Visitas pendientes
      for (final fila in await _db.query('visitas', where: "estado = 'pendiente'")) {
        final v = Visita.deFila(fila);
        final cuerpo = {...v.datos, 'id': v.id, 'revision_base': v.revisionBase, 'dispositivo_id': dispositivo};
        final r = await http.post(Uri.parse('$servidor/api/movil/visitas'), headers: {..._auth, 'content-type': 'application/json'}, body: jsonEncode(cuerpo)).timeout(const Duration(seconds: 40));
        if (r.statusCode == 401) throw _SesionVencida();
        final resp = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
        if (r.statusCode == 200) {
          // La firma ya subió: no hace falta volver a enviarla.
          final limpio = Map<String, dynamic>.from(v.datos)..remove('firma_png_base64')..remove('forzar')..['con_firma'] = v.datos['firma_png_base64'] != null || v.datos['con_firma'] == true;
          await _db.update('visitas', {'estado': 'sincronizada', 'revision_base': resp['revision'], 'json': jsonEncode(limpio), 'motivo': null}, where: 'id = ?', whereArgs: [v.id]);
        } else if (r.statusCode == 409) {
          await _db.update('visitas', {'estado': 'conflicto', 'servidor': jsonEncode(resp['servidor'])}, where: 'id = ?', whereArgs: [v.id]);
        } else {
          await _db.update('visitas', {'estado': 'rechazada', 'motivo': resp['motivo'] ?? resp['error'] ?? 'El servidor no aceptó la visita.'}, where: 'id = ?', whereArgs: [v.id]);
        }
      }
      // 2. Fotos de visitas que ya están en el servidor
      final fotosPendientes = await _db.rawQuery("select f.* from fotos f join visitas v on v.id = f.visita_id where f.subida = 0 and v.estado = 'sincronizada'");
      for (final f in fotosPendientes) {
        final archivo = File(f['ruta'] as String);
        if (!await archivo.exists()) {
          await _db.update('fotos', {'subida': 1}, where: 'id = ?', whereArgs: [f['id']]);
          continue;
        }
        final req = http.MultipartRequest('POST', Uri.parse('$servidor/api/movil/fotos'))
          ..headers.addAll(_auth)
          ..fields.addAll({
            'id': f['id'] as String, 'visita_id': f['visita_id'] as String, 'tomada_en': f['tomada_en'] as String,
            if (f['lat'] != null) 'lat': '${f['lat']}', if (f['lon'] != null) 'lon': '${f['lon']}', if (f['descripcion'] != null) 'descripcion': f['descripcion'] as String,
          })
          ..files.add(await http.MultipartFile.fromPath('archivo', archivo.path));
        final r = await req.send().timeout(const Duration(minutes: 2));
        if (r.statusCode == 401) throw _SesionVencida();
        if (r.statusCode == 200) await _db.update('fotos', {'subida': 1}, where: 'id = ?', whereArgs: [f['id']]);
      }
      // 3. Bajar predios asignados y visitas del servidor
      final r = await http.get(Uri.parse('$servidor/api/movil/paquete'), headers: _auth).timeout(const Duration(seconds: 120));
      if (r.statusCode == 401) throw _SesionVencida();
      if (r.statusCode == 200) {
        final paquete = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
        // El correo de la sesión llega con cada sincronización (los teléfonos que ya tenían sesión no lo guardaron al ingresar).
        final correoSesion = (paquete['usuario'] as Map?)?['correo'] as String?;
        if (correoSesion != null && correoSesion.isNotEmpty) await _prefs.setString('correo', correoSesion.toLowerCase());
        await _db.transaction((t) async {
          // Lo que sigue en cola (predios nuevos, polígonos por subir) se conserva tal como está en el teléfono.
          final enCola = (await t.query('cola', columns: ['predio_id'])).map((f) => f['predio_id'] as String).toSet();
          final locales = {for (final f in await t.query('predios')) f['id'] as String: f};
          await t.delete('predios');
          final llegados = <String>{};
          for (final pr in (paquete['predios'] as List).cast<Map<String, dynamic>>()) {
            final id = pr['id'] as String;
            llegados.add(id);
            final local = locales[id];
            if (local != null && enCola.contains(id)) {
              final mio = jsonDecode(local['json'] as String) as Map<String, dynamic>;
              await t.insert('predios', {'id': id, 'nombre': pr['nombre'], 'json': jsonEncode({...pr, 'poligono': mio['poligono'] ?? pr['poligono']})});
            } else {
              await t.insert('predios', {'id': id, 'nombre': pr['nombre'], 'json': jsonEncode(pr)});
            }
          }
          for (final e in locales.entries) {
            if (!llegados.contains(e.key) && enCola.contains(e.key)) await t.insert('predios', e.value);
          }
          for (final v in paquete['visitas'] as List) {
            // Lo que está pendiente o en conflicto en el teléfono no se toca.
            final local = await t.query('visitas', columns: ['estado'], where: 'id = ?', whereArgs: [v['id']]);
            if (local.isNotEmpty && local.first['estado'] != 'sincronizada') continue;
            await t.insert('visitas', {'id': v['id'], 'predio_id': v['predio_id'], 'fecha': v['fecha_hora'], 'json': jsonEncode(v), 'revision_base': v['revision'], 'estado': 'sincronizada'},
                conflictAlgorithm: ConflictAlgorithm.replace);
          }
        });
      }
      await _prefs.setString('ultima_sync', DateTime.now().toIso8601String());
      await _refrescarEstado(sinConexion: false);
    } on _SesionVencida {
      await _prefs.remove('token');
      await _refrescarEstado(error: 'La sesión venció. Ingresa de nuevo; tus datos pendientes se conservan.');
    } catch (_) {
      // Sin señal o servidor caído: todo sigue guardado en el teléfono y se reintenta después.
      await _refrescarEstado(sinConexion: true);
    } finally {
      _ocupado = false;
    }
  }
}

class _SesionVencida implements Exception {}

class EstadoSync {
  const EstadoSync({this.pendientes = 0, this.conProblema = 0, this.enCurso = false, this.sinConexion = false, this.ultima, this.error});
  final int pendientes;
  final int conProblema;
  final bool enCurso;
  final bool sinConexion;
  final String? ultima;
  final String? error;
}

class Visita {
  Visita({required this.id, required this.datos, this.revisionBase = 0, this.estado = 'pendiente', this.motivo, this.servidor});

  factory Visita.nueva(String predioId, String? acuerdoId) => Visita(
        id: const Uuid().v4(),
        datos: {'predio_id': predioId, 'acuerdo_id': acuerdoId, 'fecha_hora': DateTime.now().toUtc().toIso8601String(), 'presiones': <String>[]},
      );

  factory Visita.deFila(Map<String, Object?> f) => Visita(
        id: f['id'] as String,
        datos: jsonDecode(f['json'] as String) as Map<String, dynamic>,
        revisionBase: f['revision_base'] as int,
        estado: f['estado'] as String,
        motivo: f['motivo'] as String?,
        servidor: f['servidor'] == null ? null : jsonDecode(f['servidor'] as String) as Map<String, dynamic>,
      );

  final String id;
  final Map<String, dynamic> datos;
  final int revisionBase;
  final String estado;
  final String? motivo;
  final Map<String, dynamic>? servidor;

  DateTime get fecha => DateTime.parse(datos['fecha_hora'] as String).toLocal();
}
