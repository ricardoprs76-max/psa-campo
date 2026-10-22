import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'datos.dart';

const _verde = Color(0xFF1F7A3F);

/// Fondo del mapa: satélite (para reconocer el terreno en campo) o calles.
enum Fondo { satelite, calles }

TileLayer capaFondo(Fondo f) => f == Fondo.satelite
    ? TileLayer(
        urlTemplate: 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}',
        userAgentPackageName: 'co.psa.campo',
        maxNativeZoom: 19,
      )
    : TileLayer(urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', userAgentPackageName: 'co.psa.campo', maxNativeZoom: 19);

/// Anillos del polígono guardado (GeoJSON Polygon o MultiPolygon) como listas de puntos.
List<List<LatLng>> anillos(Map<String, dynamic>? geo) {
  if (geo == null) return [];
  final coords = geo['coordinates'] as List?;
  if (coords == null) return [];
  final out = <List<LatLng>>[];
  for (final poli in geo['type'] == 'MultiPolygon' ? coords : [coords]) {
    final exterior = (poli as List).isEmpty ? null : poli.first as List;
    if (exterior != null) out.add([for (final c in exterior) LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble())]);
  }
  return out;
}

/// Área aproximada en hectáreas (proyección local en metros; sobra precisión para un predio).
double hectareas(List<LatLng> puntos) {
  if (puntos.length < 3) return 0;
  final lat0 = puntos.map((p) => p.latitude).reduce((a, b) => a + b) / puntos.length * math.pi / 180;
  const r = 6371008.8;
  final xy = [for (final p in puntos) Offset(p.longitude * math.pi / 180 * r * math.cos(lat0), p.latitude * math.pi / 180 * r)];
  var suma = 0.0;
  for (var i = 0; i < xy.length; i++) {
    final a = xy[i], b = xy[(i + 1) % xy.length];
    suma += a.dx * b.dy - b.dx * a.dy;
  }
  return suma.abs() / 2 / 10000;
}

/// Punto de una visita (o null si no tiene GPS).
LatLng? puntoVisita(Visita v) {
  final lat = (v.datos['lat'] as num?)?.toDouble();
  final lon = (v.datos['lon'] as num?)?.toDouble();
  return lat == null || lon == null ? null : LatLng(lat, lon);
}

Widget marcadorVisita({bool porSubir = false}) => Container(
      decoration: BoxDecoration(
        color: porSubir ? Colors.orange : const Color(0xFF2563EB),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: const [BoxShadow(blurRadius: 4, color: Colors.black38)],
      ),
      child: const Icon(Icons.assignment_turned_in, color: Colors.white, size: 15),
    );

Widget marcadorYo() => Container(
      decoration: BoxDecoration(color: Colors.blue, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 3), boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black45)]),
    );

/// Encuadre inicial: el polígono y las visitas; si no hay nada, la posición actual o Boyacá.
MapOptions opcionesIniciales(List<LatLng> puntos, LatLng? aqui, {void Function(TapPosition, LatLng)? alTocar, bool interactivo = true}) {
  final todos = puntos.isNotEmpty ? puntos : [if (aqui != null) aqui];
  return MapOptions(
    initialCenter: todos.isEmpty ? const LatLng(5.55, -73.35) : todos.first,
    initialZoom: todos.isEmpty ? 8 : 16,
    initialCameraFit: todos.length >= 2 ? CameraFit.bounds(bounds: LatLngBounds.fromPoints(todos), padding: const EdgeInsets.all(48), maxZoom: 18) : null,
    maxZoom: 20,
    onTap: alTocar,
    interactionOptions: InteractionOptions(flags: interactivo ? InteractiveFlag.all & ~InteractiveFlag.rotate : InteractiveFlag.none),
  );
}

/// Vista pequeña del predio para la ficha (no se mueve; al tocarla se abre el mapa completo).
class VistaPredio extends StatelessWidget {
  const VistaPredio({super.key, required this.predio, required this.visitas, this.aqui, this.onTap});
  final Map<String, dynamic> predio;
  final List<Visita> visitas;
  final LatLng? aqui;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final poli = anillos(predio['poligono'] as Map<String, dynamic>?);
    final puntosVisitas = [for (final v in visitas) ?puntoVisita(v)];
    final encuadre = [for (final a in poli) ...a, ...puntosVisitas];
    return Stack(children: [
      FlutterMap(
        key: ValueKey('${predio['id']}-${encuadre.length}-${aqui != null && encuadre.isEmpty}'),
        options: opcionesIniciales(encuadre, aqui, interactivo: false),
        children: [
          capaFondo(Fondo.satelite),
          PolygonLayer(polygons: [for (final a in poli) Polygon(points: a, color: _verde.withValues(alpha: 0.30), borderColor: const Color(0xFF7CFC9A), borderStrokeWidth: 3)]),
          MarkerLayer(markers: [
            if (aqui != null) Marker(point: aqui!, width: 20, height: 20, child: marcadorYo()),
            for (final p in puntosVisitas) Marker(point: p, width: 26, height: 26, child: marcadorVisita()),
          ]),
        ],
      ),
      Positioned.fill(child: Material(color: Colors.transparent, child: InkWell(onTap: onTap))),
      Positioned(
        right: 8,
        bottom: 8,
        child: FilledButton.tonalIcon(onPressed: onTap, icon: const Icon(Icons.open_in_full, size: 18), label: const Text('Abrir mapa')),
      ),
    ]);
  }
}

/// Mapa completo de un predio: polígono, visitas y posición. Permite delimitar (o corregir) el polígono tocando el
/// mapa en cada esquina o caminando el borde y marcando la posición del GPS.
class MapaPredio extends StatefulWidget {
  const MapaPredio({super.key, required this.predio, required this.visitas, this.delimitar = false});
  final Map<String, dynamic> predio;
  final List<Visita> visitas;
  final bool delimitar;
  @override
  State<MapaPredio> createState() => _MapaPredioState();
}

class _MapaPredioState extends State<MapaPredio> {
  final control = MapController();
  Fondo fondo = Fondo.satelite;
  LatLng? aqui;
  double? precision;
  late bool delimitando = widget.delimitar;
  final vertices = <LatLng>[];
  bool buscando = false;
  late List<List<LatLng>> poligono = anillos(widget.predio['poligono'] as Map<String, dynamic>?);

  @override
  void initState() {
    super.initState();
    ubicarme(centrar: poligono.isEmpty && widget.visitas.every((v) => puntoVisita(v) == null));
  }

  Future<void> ubicarme({bool centrar = false, bool agregar = false}) async {
    setState(() => buscando = true);
    final pos = await posicionActual();
    if (!mounted) return;
    setState(() {
      buscando = false;
      if (pos != null) {
        aqui = LatLng(pos.latitude, pos.longitude);
        precision = pos.accuracy;
        if (agregar) vertices.add(aqui!);
      }
    });
    if (pos == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No pude obtener el GPS. Revisa que esté encendido y con permiso.')));
    } else if (centrar || agregar) {
      control.move(aqui!, agregar ? control.camera.zoom : 17);
    }
  }

  Future<void> guardar() async {
    final cerrado = [...vertices, vertices.first];
    final geo = {
      'type': 'Polygon',
      'coordinates': [
        [for (final p in cerrado) [double.parse(p.longitude.toStringAsFixed(7)), double.parse(p.latitude.toStringAsFixed(7))]]
      ],
    };
    await Datos.yo.guardarPoligono(widget.predio['id'] as String, geo);
    if (!mounted) return;
    setState(() {
      poligono = [List.of(vertices)];
      vertices.clear();
      delimitando = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Polígono guardado (≈ ${hectareas(poligono.first).toStringAsFixed(2)} ha). Se sube solo a la plataforma.')));
  }

  void verVisita(Visita v) => showModalBottomSheet(
        context: context,
        builder: (_) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Visita del ${_fecha(v.fecha)}', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (v.datos['cobertura'] != null) Text('Cobertura: ${v.datos['cobertura']}'),
            if (v.datos['estado_conservacion'] != null) Text('Estado: ${v.datos['estado_conservacion']}'),
            if (v.datos['cumple_compromisos'] != null) Text(v.datos['cumple_compromisos'] == true ? 'Cumple los compromisos' : 'No cumple los compromisos'),
            if ((v.datos['hallazgos'] as String? ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text('Hallazgos: ${v.datos['hallazgos']}')),
            const SizedBox(height: 6),
            Text(v.estado == 'sincronizada' ? 'Ya está en la plataforma.' : 'Guardada en el teléfono, por subir.', style: Theme.of(context).textTheme.bodySmall),
          ]),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    final puntosVisitas = [for (final v in widget.visitas) if (puntoVisita(v) != null) (v, puntoVisita(v)!)];
    final encuadre = [for (final a in poligono) ...a, for (final (_, p) in puntosVisitas) p];
    final area = delimitando ? hectareas(vertices) : (poligono.isEmpty ? 0.0 : poligono.map(hectareas).reduce((a, b) => a + b));
    return Scaffold(
      appBar: AppBar(
        title: Text(delimitando ? 'Delimitar polígono' : widget.predio['nombre'] as String),
        actions: [
          IconButton(
            tooltip: fondo == Fondo.satelite ? 'Ver calles' : 'Ver satélite',
            icon: Icon(fondo == Fondo.satelite ? Icons.map_outlined : Icons.satellite_alt),
            onPressed: () => setState(() => fondo = fondo == Fondo.satelite ? Fondo.calles : Fondo.satelite),
          ),
        ],
      ),
      body: Stack(children: [
        FlutterMap(
          mapController: control,
          options: opcionesIniciales(encuadre, aqui, alTocar: (_, punto) {
            if (delimitando) setState(() => vertices.add(punto));
          }),
          children: [
            capaFondo(fondo),
            PolygonLayer(polygons: [
              for (final a in poligono)
                Polygon(points: a, color: _verde.withValues(alpha: delimitando ? 0.12 : 0.30), borderColor: const Color(0xFF7CFC9A), borderStrokeWidth: 3),
              if (delimitando && vertices.length >= 3) Polygon(points: vertices, color: Colors.amber.withValues(alpha: 0.30), borderColor: Colors.amber, borderStrokeWidth: 3),
            ]),
            if (delimitando && vertices.length == 2) PolylineLayer(polylines: [Polyline(points: vertices, color: Colors.amber, strokeWidth: 3)]),
            MarkerLayer(markers: [
              if (aqui != null) Marker(point: aqui!, width: 22, height: 22, child: marcadorYo()),
              for (final (v, p) in puntosVisitas)
                Marker(point: p, width: 30, height: 30, child: GestureDetector(onTap: () => verVisita(v), child: marcadorVisita(porSubir: v.estado != 'sincronizada'))),
              if (delimitando)
                for (final (i, p) in vertices.indexed)
                  Marker(
                    point: p,
                    width: 26,
                    height: 26,
                    child: Container(
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: Colors.amber, shape: BoxShape.circle, border: Border.all(color: Colors.white, width: 2)),
                      child: Text('${i + 1}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black)),
                    ),
                  ),
            ]),
            RichAttributionWidget(alignment: AttributionAlignment.bottomLeft, attributions: [TextSourceAttribution(fondo == Fondo.satelite ? 'Esri, Maxar, Earthstar Geographics' : '© OpenStreetMap')]),
          ],
        ),
        // Aviso de arriba
        Positioned(
          left: 12,
          right: 12,
          top: 12,
          child: Card(
            color: esquema.surface.withValues(alpha: 0.92),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                delimitando
                    ? 'Toca el mapa en cada esquina del predio, en orden, o camina el borde y toca «Mi posición» en cada esquina. '
                        '${vertices.length} punto(s)${vertices.length >= 3 ? ' · ≈ ${area.toStringAsFixed(2)} ha' : ''}'
                    : poligono.isEmpty
                        ? 'Este predio aún no tiene polígono. Toca «Delimitar» para marcarlo.'
                        : 'Polígono del predio (≈ ${area.toStringAsFixed(2)} ha) · ${puntosVisitas.length} visita(s) en el mapa${aqui != null ? ' · punto azul: tú${precision != null ? ' (± ${precision!.toStringAsFixed(0)} m)' : ''}' : ''}.',
              ),
            ),
          ),
        ),
        // Leyenda de las visitas
        if (!delimitando && puntosVisitas.isNotEmpty)
          Positioned(
            left: 12,
            bottom: 96,
            child: Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                child: Row(mainAxisSize: MainAxisSize.min, children: [SizedBox(width: 18, height: 18, child: marcadorVisita()), const SizedBox(width: 6), const Text('Visita de campo (toca para ver)')]),
              ),
            ),
          ),
      ]),
      floatingActionButton: FloatingActionButton.small(
        heroTag: 'yo',
        tooltip: 'Mi posición',
        onPressed: buscando ? null : () => ubicarme(centrar: true),
        child: buscando ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.my_location),
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: delimitando
              ? Wrap(spacing: 8, runSpacing: 8, alignment: WrapAlignment.center, children: [
                  OutlinedButton.icon(onPressed: buscando ? null : () => ubicarme(agregar: true), icon: const Icon(Icons.add_location_alt), label: const Text('Mi posición')),
                  OutlinedButton.icon(onPressed: vertices.isEmpty ? null : () => setState(vertices.removeLast), icon: const Icon(Icons.undo), label: const Text('Deshacer')),
                  TextButton(onPressed: () => setState(() { vertices.clear(); delimitando = false; }), child: const Text('Cancelar')),
                  FilledButton.icon(onPressed: vertices.length < 3 ? null : guardar, icon: const Icon(Icons.check), label: const Text('Guardar polígono')),
                ])
              : FilledButton.icon(
                  onPressed: () => setState(() {
                    delimitando = true;
                    vertices.clear();
                  }),
                  icon: const Icon(Icons.draw),
                  label: Text(poligono.isEmpty ? 'Delimitar polígono' : 'Volver a delimitar el polígono'),
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                ),
        ),
      ),
    );
  }
}

/// Mapa con todos los predios asignados y las visitas.
class MapaGeneral extends StatefulWidget {
  const MapaGeneral({super.key, required this.predios, required this.visitas, required this.abrir});
  final List<Map<String, dynamic>> predios;
  final List<Visita> visitas;
  final void Function(Map<String, dynamic>) abrir;
  @override
  State<MapaGeneral> createState() => _MapaGeneralState();
}

class _MapaGeneralState extends State<MapaGeneral> {
  Fondo fondo = Fondo.satelite;
  LatLng? aqui;

  @override
  void initState() {
    super.initState();
    posicionActual().then((p) {
      if (mounted && p != null) setState(() => aqui = LatLng(p.latitude, p.longitude));
    });
  }

  @override
  Widget build(BuildContext context) {
    final poligonos = [for (final pr in widget.predios) (pr, anillos(pr['poligono'] as Map<String, dynamic>?))];
    final visitas = [for (final v in widget.visitas) if (puntoVisita(v) != null) (v, puntoVisita(v)!)];
    final encuadre = [for (final (_, a) in poligonos) for (final r in a) ...r, for (final (_, p) in visitas) p];
    LatLng? centro(List<List<LatLng>> a) {
      final pts = [for (final r in a) ...r];
      if (pts.isEmpty) return null;
      return LatLng(pts.map((p) => p.latitude).reduce((x, y) => x + y) / pts.length, pts.map((p) => p.longitude).reduce((x, y) => x + y) / pts.length);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Mapa de mis predios'), actions: [
        IconButton(
          tooltip: fondo == Fondo.satelite ? 'Ver calles' : 'Ver satélite',
          icon: Icon(fondo == Fondo.satelite ? Icons.map_outlined : Icons.satellite_alt),
          onPressed: () => setState(() => fondo = fondo == Fondo.satelite ? Fondo.calles : Fondo.satelite),
        ),
      ]),
      body: FlutterMap(
        key: ValueKey('${encuadre.length}-${aqui != null}'),
        options: opcionesIniciales(encuadre, aqui),
        children: [
          capaFondo(fondo),
          PolygonLayer(polygons: [
            for (final (_, a) in poligonos)
              for (final r in a) Polygon(points: r, color: _verde.withValues(alpha: 0.30), borderColor: const Color(0xFF7CFC9A), borderStrokeWidth: 3),
          ]),
          MarkerLayer(markers: [
            if (aqui != null) Marker(point: aqui!, width: 20, height: 20, child: marcadorYo()),
            for (final (v, p) in visitas) Marker(point: p, width: 26, height: 26, child: marcadorVisita(porSubir: v.estado != 'sincronizada')),
            for (final (pr, a) in poligonos)
              if (centro(a) != null)
                Marker(
                  point: centro(a)!,
                  width: 170,
                  height: 36,
                  child: GestureDetector(
                    onTap: () => widget.abrir(pr),
                    child: Center(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(color: Colors.black.withValues(alpha: 0.65), borderRadius: BorderRadius.circular(8)),
                        child: Text(pr['nombre'] as String, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
                      ),
                    ),
                  ),
                ),
          ]),
          RichAttributionWidget(alignment: AttributionAlignment.bottomLeft, attributions: [TextSourceAttribution(fondo == Fondo.satelite ? 'Esri, Maxar, Earthstar Geographics' : '© OpenStreetMap')]),
        ],
      ),
    );
  }
}

String _dos(int n) => n.toString().padLeft(2, '0');
String _fecha(DateTime f) => '${_dos(f.day)}/${_dos(f.month)}/${f.year} ${_dos(f.hour)}:${_dos(f.minute)}';

/// Posición actual por el GPS del teléfono, o null si no hay permiso o está apagado.
Future<Position?> posicionActual() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var permiso = await Geolocator.checkPermission();
    if (permiso == LocationPermission.denied) permiso = await Geolocator.requestPermission();
    if (permiso == LocationPermission.denied || permiso == LocationPermission.deniedForever) return null;
    return await Geolocator.getCurrentPosition(locationSettings: AndroidSettings(accuracy: LocationAccuracy.best, forceLocationManager: true, timeLimit: const Duration(seconds: 25)));
  } catch (_) {
    return null;
  }
}
