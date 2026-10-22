import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:geolocator/geolocator.dart';
import 'package:image_picker/image_picker.dart';
import 'package:latlong2/latlong.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'datos.dart';
import 'mapa.dart';

const verde = Color(0xFF1F7A3F);
const verdeOscuro = Color(0xFF14532D);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Datos.yo.abrir();
  runApp(const PsaCampo());
}

class PsaCampo extends StatelessWidget {
  const PsaCampo({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'PSA Campo',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: verde), useMaterial3: true),
        darkTheme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: verde, brightness: Brightness.dark), useMaterial3: true),
        home: Datos.yo.token == null ? const Ingreso() : const Inicio(),
      );
}

String dos(int n) => n.toString().padLeft(2, '0');
String fechaCorta(DateTime f) => '${dos(f.day)}/${dos(f.month)}/${f.year} ${dos(f.hour)}:${dos(f.minute)}';

// ---------------------------------------------------------------- Ingreso

class Ingreso extends StatefulWidget {
  const Ingreso({super.key});
  @override
  State<Ingreso> createState() => _IngresoState();
}

class _IngresoState extends State<Ingreso> {
  final servidor = TextEditingController(text: Datos.yo.servidor);
  final correo = TextEditingController();
  // Todas las personas usan la contraseña común que da la oficina; lo que identifica a cada quien es su correo.
  final clave = TextEditingController();
  String? error;
  bool cargando = false;

  Future<void> entrar() async {
    setState(() {
      cargando = true;
      error = null;
    });
    final e = await Datos.yo.ingresar(servidor.text, correo.text, clave.text);
    if (!mounted) return;
    if (e == null) {
      Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const Inicio()));
    } else {
      setState(() {
        cargando = false;
        error = e;
      });
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Image.asset('assets/emblema.png', height: 110),
                const SizedBox(height: 12),
                Text('PSA Campo', textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
                Text('Visitas de Pagos por Servicios Ambientales', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 28),
                TextField(controller: correo, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Correo', helperText: 'Cualquier correo sirve: la primera vez tu usuario se crea solo.\nTus visitas quedan registradas con este correo.', helperMaxLines: 3, border: OutlineInputBorder())),
                const SizedBox(height: 12),
                TextField(controller: clave, obscureText: true, decoration: const InputDecoration(labelText: 'Contraseña', helperText: 'La contraseña común que te dio la oficina', border: OutlineInputBorder()), onSubmitted: (_) => entrar()),
                const SizedBox(height: 12),
                TextField(controller: servidor, keyboardType: TextInputType.url, autocorrect: false, decoration: const InputDecoration(labelText: 'Dirección de la plataforma', helperText: 'El enlace con el que se abre el Sistema PSA', border: OutlineInputBorder())),
                if (error != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(error!, style: TextStyle(color: Theme.of(context).colorScheme.error))),
                const SizedBox(height: 20),
                FilledButton(onPressed: cargando ? null : entrar, style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)), child: Text(cargando ? 'Ingresando… (puede tardar un minuto)' : 'Ingresar')),
              ]),
            ),
          ),
        ),
      );
}

// ---------------------------------------------------------------- Indicador de sincronización

class BarraSync extends StatelessWidget {
  const BarraSync({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<EstadoSync>(
        valueListenable: Datos.yo.estado,
        builder: (context, e, _) {
          final esquema = Theme.of(context).colorScheme;
          final (IconData icono, String texto, Color color) = e.error != null
              ? (Icons.lock_clock, e.error!, esquema.errorContainer)
              : e.enCurso
                  ? (Icons.sync, 'Sincronizando…', esquema.secondaryContainer)
                  : e.conProblema > 0
                      ? (Icons.warning_amber, '${e.conProblema} visita(s) necesitan tu atención', esquema.errorContainer)
                      : e.pendientes > 0
                          ? (e.sinConexion ? Icons.cloud_off : Icons.cloud_upload, '${e.pendientes} por subir${e.sinConexion ? ' · sin conexión, se envían solas' : ''}', esquema.tertiaryContainer)
                          : (e.sinConexion ? Icons.cloud_off : Icons.cloud_done, e.sinConexion ? 'Sin conexión · todo guardado en el teléfono' : 'Todo sincronizado', esquema.primaryContainer);
          return Material(
            color: color,
            child: InkWell(
              onTap: Datos.yo.sincronizar,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(children: [Icon(icono, size: 20), const SizedBox(width: 10), Expanded(child: Text(texto)), if (!e.enCurso) const Text('Sincronizar', style: TextStyle(fontWeight: FontWeight.w600))]),
              ),
            ),
          );
        },
      );
}

// ---------------------------------------------------------------- Predios asignados

class Inicio extends StatefulWidget {
  const Inicio({super.key});
  @override
  State<Inicio> createState() => _InicioState();
}

class _InicioState extends State<Inicio> with WidgetsBindingObserver {
  List<Map<String, dynamic>> predios = [];
  List<Visita> visitas = [];
  List<Map<String, Object?>> rechazados = [];
  Set<String> porSubir = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    Datos.yo.estado.addListener(cargar);
    cargar();
    Datos.yo.sincronizar();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    Datos.yo.estado.removeListener(cargar);
    super.dispose();
  }

  // Al volver a la app se intenta sincronizar de una vez.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) Datos.yo.sincronizar();
  }

  Future<void> cargar() async {
    final pr = await Datos.yo.predios();
    final vi = await Datos.yo.visitas();
    final re = await Datos.yo.colaConProblema();
    final ps = await Datos.yo.prediosPorSubir();
    if (!mounted) return;
    if (Datos.yo.token == null) {
      // La sesión venció: se vuelve al ingreso. Lo pendiente sigue guardado.
      Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const Ingreso()), (_) => false);
      return;
    }
    setState(() {
      predios = pr;
      visitas = vi;
      rechazados = re;
      porSubir = ps;
    });
  }

  void abrirPredio(Map<String, dynamic> pr) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => FichaPredio(predio: pr))).then((_) => cargar());

  /// Cerrar sesión para entrar con otro correo. Lo que no ha subido se avisa antes de borrarlo del teléfono.
  Future<void> cambiarCorreo() async {
    final pendientes = await Datos.yo.sinSubir();
    if (!mounted) return;
    final opcion = await showDialog<String>(
      context: context,
      builder: (c) => AlertDialog(
        title: const Text('¿Cerrar sesión?'),
        content: Text(pendientes == 0
            ? 'Sales de ${Datos.yo.correo.isEmpty ? 'esta cuenta' : Datos.yo.correo} y podrás entrar con otro correo. Todo lo tuyo ya está en la plataforma.'
            : 'Hay $pendientes cosa(s) de esta cuenta que aún no suben a la plataforma (visitas, fotos o predios). '
                'Si cierras sesión ahora se borran del teléfono. Mejor sincroniza primero con internet.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(c), child: const Text('Cancelar')),
          if (pendientes > 0) TextButton(onPressed: () => Navigator.pop(c, 'sync'), child: const Text('Sincronizar ahora')),
          FilledButton(
            onPressed: () => Navigator.pop(c, 'salir'),
            style: pendientes > 0 ? FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error) : null,
            child: Text(pendientes > 0 ? 'Cerrar y borrar' : 'Cerrar sesión'),
          ),
        ],
      ),
    );
    if (opcion == 'sync') {
      await Datos.yo.sincronizar();
      return;
    }
    if (opcion != 'salir') return;
    Datos.yo.estado.removeListener(cargar);
    await Datos.yo.salir();
    if (mounted) Navigator.of(context).pushAndRemoveUntil(MaterialPageRoute(builder: (_) => const Ingreso()), (_) => false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          backgroundColor: verdeOscuro,
          foregroundColor: Colors.white,
          title: Row(children: [Image.asset('assets/logo.png', height: 34), const SizedBox(width: 10), const Text('PSA Campo')]),
          actions: [
            IconButton(
              tooltip: 'Mapa de mis predios',
              icon: const Icon(Icons.map),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => MapaGeneral(predios: predios, visitas: visitas, abrir: abrirPredio))),
            ),
            PopupMenuButton<String>(
              tooltip: 'Cuenta',
              icon: const Icon(Icons.account_circle),
              onSelected: (v) {
                if (v == 'salir') cambiarCorreo();
              },
              itemBuilder: (_) => [
                PopupMenuItem(enabled: false, child: Text(Datos.yo.correo.isEmpty ? Datos.yo.usuario : Datos.yo.correo)),
                const PopupMenuItem(value: 'salir', child: ListTile(leading: Icon(Icons.logout), title: Text('Cerrar sesión / cambiar de correo'), contentPadding: EdgeInsets.zero)),
              ],
            ),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          icon: const Icon(Icons.add_home_work),
          label: const Text('Nuevo predio'),
          onPressed: () async {
            final nuevo = await Navigator.of(context).push<Map<String, dynamic>>(MaterialPageRoute(builder: (_) => const NuevoPredio()));
            await cargar();
            if (nuevo != null && mounted) abrirPredio(nuevo);
          },
        ),
        body: Column(children: [
          const BarraSync(),
          Expanded(
            child: predios.isEmpty && rechazados.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                          'Hola, ${Datos.yo.usuario}.\n${Datos.yo.correo.isEmpty ? '' : 'Registras como ${Datos.yo.correo}\n'}\nAún no tienes predios asignados, o falta la primera sincronización. '
                          'Coordinación los asigna desde la plataforma web, o puedes crear uno con «Nuevo predio».',
                          textAlign: TextAlign.center),
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: Datos.yo.sincronizar,
                    child: ListView(padding: const EdgeInsets.fromLTRB(12, 12, 12, 96), children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                        child: Text('Hola, ${Datos.yo.usuario} · Predios (${predios.length})${Datos.yo.correo.isEmpty ? '' : '\nRegistras como ${Datos.yo.correo}'}', style: Theme.of(context).textTheme.titleMedium),
                      ),
                      for (final r in rechazados)
                        Card(
                          color: Theme.of(context).colorScheme.errorContainer,
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text(r['tipo'] == 'predio' ? 'El predio nuevo no se pudo subir' : 'El polígono no se pudo subir', style: const TextStyle(fontWeight: FontWeight.w600)),
                              Text('${r['motivo'] ?? ''}'),
                              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                                TextButton(onPressed: () => Datos.yo.descartarCola(r['id'] as String), child: const Text('Descartar')),
                                TextButton(onPressed: () => Datos.yo.reintentarCola(r['id'] as String), child: const Text('Reintentar')),
                              ]),
                            ]),
                          ),
                        ),
                      for (final pr in predios)
                        Card(
                          child: ListTile(
                            leading: const CircleAvatar(backgroundColor: verde, foregroundColor: Colors.white, child: Icon(Icons.landscape)),
                            title: Text(pr['nombre'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                            subtitle: Text('${[pr['vereda'], pr['municipio']].where((x) => x != null && '$x'.isNotEmpty).join(', ')}\n'
                                '${visitas.where((v) => v.datos['predio_id'] == pr['id']).length} visita(s)${pr['poligono'] == null ? ' · sin polígono' : ''}${porSubir.contains(pr['id']) ? ' · por subir' : ''}'),
                            isThreeLine: true,
                            trailing: const Icon(Icons.chevron_right),
                            onTap: () => abrirPredio(pr),
                          ),
                        ),
                    ]),
                  ),
          ),
        ]),
      );
}

// ---------------------------------------------------------------- Ficha del predio

class FichaPredio extends StatefulWidget {
  const FichaPredio({super.key, required this.predio});
  final Map<String, dynamic> predio;
  @override
  State<FichaPredio> createState() => _FichaPredioState();
}

class _FichaPredioState extends State<FichaPredio> {
  List<Visita> visitas = [];
  Position? aqui;
  late Map<String, dynamic> pr = widget.predio;

  @override
  void initState() {
    super.initState();
    Datos.yo.estado.addListener(cargar);
    cargar();
    ubicar().then((pos) {
      if (mounted) setState(() => aqui = pos);
    });
  }

  @override
  void dispose() {
    Datos.yo.estado.removeListener(cargar);
    super.dispose();
  }

  Future<void> cargar() async {
    final v = await Datos.yo.visitas(predioId: widget.predio['id'] as String);
    // El predio se relee: pudo cambiar su polígono o llegar datos nuevos de la plataforma.
    final todos = await Datos.yo.predios();
    final actual = todos.where((x) => x['id'] == widget.predio['id']).firstOrNull;
    if (mounted) {
      setState(() {
        visitas = v;
        if (actual != null) pr = actual;
      });
    }
  }

  void abrirMapa({bool delimitar = false}) => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => MapaPredio(predio: pr, visitas: visitas, delimitar: delimitar)))
      .then((_) => cargar());

  @override
  Widget build(BuildContext context) {
    final acuerdos = (pr['acuerdos'] as List? ?? []).cast<Map<String, dynamic>>();
    final titulares = (pr['titulares'] as List? ?? []).cast<Map<String, dynamic>>();
    Widget dato(String e, Object? v) => v == null || '$v'.isEmpty
        ? const SizedBox.shrink()
        : Padding(padding: const EdgeInsets.only(bottom: 6), child: Text.rich(TextSpan(children: [TextSpan(text: '$e: ', style: const TextStyle(fontWeight: FontWeight.w600)), TextSpan(text: '$v')])));
    return Scaffold(
      appBar: AppBar(title: Text(pr['nombre'] as String), actions: [IconButton(tooltip: 'Mapa', icon: const Icon(Icons.map), onPressed: abrirMapa)]),
      floatingActionButton: FloatingActionButton.extended(
        icon: const Icon(Icons.add),
        label: const Text('Nueva visita'),
        onPressed: () => Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => FormularioVisita(predio: pr, visita: Visita.nueva(pr['id'] as String, acuerdos.isEmpty ? null : acuerdos.first['id'] as String?))))
            .then((_) => cargar()),
      ),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 96), children: [
        // Mapa del predio con fondo satelital: polígono, visitas y tu posición. Sin internet el fondo no carga,
        // pero el polígono y los puntos sí se ven.
        Card(
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            height: 240,
            child: VistaPredio(predio: pr, visitas: visitas, aqui: aqui == null ? null : LatLng(aqui!.latitude, aqui!.longitude), onTap: abrirMapa),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(children: [
            Expanded(
              child: Text(
                pr['poligono'] == null
                    ? 'Este predio aún no tiene polígono.'
                    : 'Verde: polígono · azul: visitas${aqui == null ? '' : ' · punto azul con borde: tú'}.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            TextButton.icon(onPressed: () => abrirMapa(delimitar: true), icon: const Icon(Icons.draw, size: 18), label: Text(pr['poligono'] == null ? 'Delimitar' : 'Redelimitar')),
          ]),
        ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              dato('Ubicación', [pr['vereda'], pr['municipio'], pr['departamento']].where((x) => x != null && '$x'.trim().isNotEmpty).join(', ')),
              dato('Matrícula', pr['fmi']),
              dato('Área total', pr['area_total_ha'] == null ? null : '${pr['area_total_ha']} ha'),
              dato('Área en conservación', pr['area_conservacion_ha'] == null ? null : '${pr['area_conservacion_ha']} ha'),
              dato('Altitud', pr['altitud_min'] == null ? null : '${pr['altitud_min']} – ${pr['altitud_max']} msnm'),
              dato('Ecosistema', pr['ecosistema_estrategico']),
              dato('Uso permitido', pr['uso_permitido']),
              dato('Uso prohibido', pr['uso_prohibido']),
              dato('Infraestructura', pr['infraestructura']),
              for (final t in titulares) dato('Titular', '${t['nombre']}${t['representante'] != null ? ' · ${t['representante']}' : ''}${t['telefono'] != null ? ' · ${t['telefono']}' : ''}'),
              for (final a in acuerdos) dato('Compromisos (${a['codigo'] ?? 'acuerdo'})', a['compromisos'] ?? 'sin compromisos registrados'),
            ]),
          ),
        ),
        Padding(padding: const EdgeInsets.fromLTRB(4, 14, 4, 6), child: Text('Visitas', style: Theme.of(context).textTheme.titleMedium)),
        if (visitas.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Sin visitas todavía.')),
        for (final v in visitas)
          Card(
            child: ListTile(
              leading: Icon(
                switch (v.estado) { 'sincronizada' => Icons.cloud_done, 'conflicto' => Icons.call_split, 'rechazada' => Icons.error_outline, _ => Icons.cloud_upload },
                color: v.estado == 'sincronizada'
                    ? verde
                    : v.estado == 'pendiente'
                        ? Colors.orange
                        : Theme.of(context).colorScheme.error,
              ),
              title: Text(fechaCorta(v.fecha)),
              subtitle: Text(switch (v.estado) {
                'sincronizada' => Datos.yo.correo.isEmpty ? 'Sincronizada' : 'Sincronizada · registrada por ${Datos.yo.correo}',
                'conflicto' => 'Conflicto: toca para resolver',
                'rechazada' => 'No aceptada: ${v.motivo}',
                _ => 'Guardada en el teléfono, por subir',
              }),
              onTap: () => Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => v.estado == 'conflicto' ? Conflicto(visita: v) : FormularioVisita(predio: pr, visita: v)))
                  .then((_) => cargar()),
            ),
          ),
      ]),
    );
  }
}

/// Posición actual, o null si no hay permiso o el GPS está apagado.
Future<Position?> ubicar() async {
  try {
    if (!await Geolocator.isLocationServiceEnabled()) return null;
    var permiso = await Geolocator.checkPermission();
    if (permiso == LocationPermission.denied) permiso = await Geolocator.requestPermission();
    if (permiso == LocationPermission.denied || permiso == LocationPermission.deniedForever) return null;
    // GPS del teléfono directamente: funciona sin datos y no pide activar la "precisión de ubicación" de Google.
    return await Geolocator.getCurrentPosition(locationSettings: AndroidSettings(accuracy: LocationAccuracy.best, forceLocationManager: true, timeLimit: const Duration(seconds: 25)));
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------- Formulario de visita

const coberturas = ['Páramo', 'Bosque altoandino', 'Bosque secundario', 'Rastrojo', 'Pastos', 'Cultivos', 'Humedal', 'Otra'];
const estados = ['Muy bueno', 'Bueno', 'Regular', 'Deteriorado', 'Muy deteriorado'];
const presionesPosibles = ['Ganado', 'Cultivos', 'Tala', 'Quemas', 'Cacería', 'Residuos', 'Especies invasoras', 'Minería', 'Captaciones no autorizadas', 'Ninguna'];

class FormularioVisita extends StatefulWidget {
  const FormularioVisita({super.key, required this.predio, required this.visita});
  final Map<String, dynamic> predio;
  final Visita visita;
  @override
  State<FormularioVisita> createState() => _FormularioVisitaState();
}

class _FormularioVisitaState extends State<FormularioVisita> {
  late final Map<String, dynamic> d = Map<String, dynamic>.from(widget.visita.datos);
  late final hallazgos = TextEditingController(text: d['hallazgos'] as String? ?? '');
  late final recomendaciones = TextEditingController(text: d['recomendaciones'] as String? ?? '');
  late final detalle = TextEditingController(text: d['cumplimiento_detalle'] as String? ?? '');
  late final firmante = TextEditingController(text: d['firmante_nombre'] as String? ?? '');
  late final documento = TextEditingController(text: d['firmante_documento'] as String? ?? '');
  final llaveFirma = GlobalKey();
  final trazos = <List<Offset>>[];
  List<Map<String, Object?>> fotos = [];
  bool buscandoGps = false;

  @override
  void initState() {
    super.initState();
    cargarFotos();
    if (d['lat'] == null) tomarGps();
  }

  Future<void> cargarFotos() async {
    final f = await Datos.yo.fotos(widget.visita.id);
    if (mounted) setState(() => fotos = f);
  }

  Future<void> tomarGps() async {
    setState(() => buscandoGps = true);
    final pos = await ubicar();
    if (!mounted) return;
    setState(() {
      buscandoGps = false;
      if (pos != null) {
        d['lat'] = pos.latitude;
        d['lon'] = pos.longitude;
        d['precision_m'] = double.parse(pos.accuracy.toStringAsFixed(1));
        d['altitud'] = double.parse(pos.altitude.toStringAsFixed(1));
      }
    });
    if (pos == null) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No pude obtener el GPS. Revisa que esté encendido y con permiso.')));
  }

  Future<void> tomarFoto() async {
    final toma = await ImagePicker().pickImage(source: ImageSource.camera, imageQuality: 80, maxWidth: 2000);
    if (toma == null) return;
    // La foto se copia a la carpeta de la app y se le anotan las coordenadas y la hora de ese momento.
    final carpeta = Directory(p.join((await getApplicationDocumentsDirectory()).path, 'fotos'))..createSync(recursive: true);
    final destino = p.join(carpeta.path, '${DateTime.now().millisecondsSinceEpoch}.jpg');
    await File(toma.path).copy(destino);
    final pos = await ubicar();
    await Datos.yo.agregarFoto(widget.visita.id, destino, pos?.latitude ?? (d['lat'] as num?)?.toDouble(), pos?.longitude ?? (d['lon'] as num?)?.toDouble(), null);
    await cargarFotos();
  }

  Future<String?> firmaPng() async {
    if (trazos.isEmpty) return null;
    final borde = llaveFirma.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final imagen = await borde.toImage(pixelRatio: 2);
    final bytes = await imagen.toByteData(format: ui.ImageByteFormat.png);
    return base64Encode(bytes!.buffer.asUint8List());
  }

  Future<void> guardar() async {
    if (d['cobertura'] == null || d['estado_conservacion'] == null) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Indica la cobertura y el estado de conservación.')));
      return;
    }
    final firma = await firmaPng();
    d
      ..['hallazgos'] = hallazgos.text.trim()
      ..['recomendaciones'] = recomendaciones.text.trim()
      ..['cumplimiento_detalle'] = detalle.text.trim()
      ..['firmante_nombre'] = firmante.text.trim()
      ..['firmante_documento'] = documento.text.trim();
    if (firma != null) d['firma_png_base64'] = firma;
    await Datos.yo.guardarVisita(Visita(id: widget.visita.id, datos: d, revisionBase: widget.visita.revisionBase));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Visita guardada en el teléfono. Se sube sola cuando haya conexión.')));
    Navigator.of(context).pop();
  }

  // Si la visita trae un valor que no está en la lista (por ejemplo, escrito desde la web), se conserva como opción.
  List<DropdownMenuItem<String>> opciones(List<String> lista, Object? actual) =>
      [for (final c in {...lista, if (actual is String && actual.isNotEmpty) actual}) DropdownMenuItem(value: c, child: Text(c, overflow: TextOverflow.ellipsis))];

  void trazo(Offset punto, {bool nuevo = false}) => setState(() => nuevo ? trazos.add([punto]) : trazos.last.add(punto));

  @override
  Widget build(BuildContext context) {
    final esquema = Theme.of(context).colorScheme;
    final presiones = (d['presiones'] as List? ?? []).map((e) => '$e').toList();
    Widget titulo(String t) => Padding(padding: const EdgeInsets.fromLTRB(0, 18, 0, 8), child: Text(t, style: Theme.of(context).textTheme.titleMedium));
    final yaFirmada = d['con_firma'] == true || d['firma_png_base64'] != null;
    return Scaffold(
      appBar: AppBar(title: Text('Visita · ${widget.predio['nombre']}')),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(onPressed: guardar, icon: const Icon(Icons.save), label: const Text('Guardar visita'), style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52))),
        ),
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Card(
          color: esquema.secondaryContainer,
          child: ListTile(
            leading: Icon(d['lat'] == null ? Icons.gps_not_fixed : Icons.gps_fixed),
            title: Text(d['lat'] == null ? (buscandoGps ? 'Buscando GPS…' : 'Sin ubicación') : '${(d['lat'] as num).toStringAsFixed(6)}, ${(d['lon'] as num).toStringAsFixed(6)}'),
            subtitle: Text('${fechaCorta(widget.visita.fecha)}${d['precision_m'] != null ? ' · ± ${d['precision_m']} m' : ''}${d['altitud'] != null ? ' · ${d['altitud']} msnm' : ''}'),
            trailing: IconButton(icon: const Icon(Icons.refresh), tooltip: 'Tomar de nuevo', onPressed: buscandoGps ? null : tomarGps),
          ),
        ),
        titulo('Cobertura y estado'),
        DropdownButtonFormField<String>(
          initialValue: d['cobertura'] as String?,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Cobertura predominante', border: OutlineInputBorder()),
          items: opciones(coberturas, d['cobertura']),
          onChanged: (v) => setState(() => d['cobertura'] = v),
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          initialValue: d['estado_conservacion'] as String?,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Estado de conservación', border: OutlineInputBorder()),
          items: opciones(estados, d['estado_conservacion']),
          onChanged: (v) => setState(() => d['estado_conservacion'] = v),
        ),
        titulo('Presiones observadas'),
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final pr in {...presionesPosibles, ...presiones})
            FilterChip(
              label: Text(pr),
              selected: presiones.contains(pr),
              onSelected: (s) => setState(() {
                s ? presiones.add(pr) : presiones.remove(pr);
                d['presiones'] = presiones;
              }),
            ),
        ]),
        titulo('Cumplimiento de compromisos'),
        SegmentedButton<bool>(
          emptySelectionAllowed: true,
          segments: const [ButtonSegment(value: true, label: Text('Cumple'), icon: Icon(Icons.check)), ButtonSegment(value: false, label: Text('No cumple'), icon: Icon(Icons.close))],
          selected: {if (d['cumple_compromisos'] != null) d['cumple_compromisos'] as bool},
          onSelectionChanged: (s) => setState(() => d['cumple_compromisos'] = s.isEmpty ? null : s.first),
        ),
        const SizedBox(height: 12),
        TextField(controller: detalle, maxLines: 2, decoration: const InputDecoration(labelText: 'Detalle del cumplimiento', border: OutlineInputBorder())),
        titulo('Hallazgos y recomendaciones'),
        TextField(controller: hallazgos, maxLines: 4, decoration: const InputDecoration(labelText: 'Hallazgos', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(controller: recomendaciones, maxLines: 3, decoration: const InputDecoration(labelText: 'Recomendaciones', border: OutlineInputBorder())),
        titulo('Fotos (${fotos.length})'),
        SizedBox(
          height: 110,
          child: ListView(scrollDirection: Axis.horizontal, children: [
            InkWell(
              onTap: tomarFoto,
              child: Container(
                width: 110,
                decoration: BoxDecoration(border: Border.all(color: esquema.outline), borderRadius: BorderRadius.circular(12)),
                child: const Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.add_a_photo, size: 30), SizedBox(height: 6), Text('Tomar foto')]),
              ),
            ),
            for (final f in fotos)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Stack(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.file(File(f['ruta'] as String), width: 110, height: 110, fit: BoxFit.cover, errorBuilder: (_, _, _) => const SizedBox(width: 110, height: 110, child: Icon(Icons.image_not_supported))),
                  ),
                  Positioned(right: 4, bottom: 4, child: Icon(f['subida'] == 1 ? Icons.cloud_done : Icons.cloud_upload, color: Colors.white, size: 18)),
                  if (f['lat'] != null) const Positioned(left: 4, bottom: 4, child: Icon(Icons.place, color: Colors.white, size: 18)),
                ]),
              ),
          ]),
        ),
        const SizedBox(height: 4),
        Text('Cada foto guarda la hora y las coordenadas del momento.', style: Theme.of(context).textTheme.bodySmall),
        titulo('Firma del beneficiario'),
        TextField(controller: firmante, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Nombre de quien firma', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        TextField(controller: documento, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Cédula', border: OutlineInputBorder())),
        const SizedBox(height: 12),
        if (yaFirmada && trazos.isEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Esta visita ya tiene firma. Si se firma de nuevo aquí, la reemplaza.', style: Theme.of(context).textTheme.bodySmall)),
        RepaintBoundary(
          key: llaveFirma,
          child: Container(
            height: 170,
            decoration: BoxDecoration(color: Colors.white, border: Border.all(color: esquema.outline), borderRadius: BorderRadius.circular(12)),
            // Arrastres vertical y horizontal por separado para que el trazo le gane al desplazamiento de la pantalla.
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (e) => trazo(e.localPosition, nuevo: true),
              onVerticalDragStart: (e) => trazo(e.localPosition, nuevo: true),
              onVerticalDragUpdate: (e) => trazo(e.localPosition),
              onHorizontalDragStart: (e) => trazo(e.localPosition, nuevo: true),
              onHorizontalDragUpdate: (e) => trazo(e.localPosition),
              child: ClipRRect(borderRadius: BorderRadius.circular(12), child: CustomPaint(painter: Firma(trazos), child: const SizedBox.expand())),
            ),
          ),
        ),
        Align(alignment: Alignment.centerRight, child: TextButton.icon(onPressed: trazos.isEmpty ? null : () => setState(trazos.clear), icon: const Icon(Icons.clear), label: const Text('Borrar firma'))),
      ]),
    );
  }
}

class Firma extends CustomPainter {
  Firma(this.trazos);
  final List<List<Offset>> trazos;

  @override
  void paint(Canvas canvas, Size size) {
    final lapiz = Paint()
      ..color = Colors.black
      ..strokeWidth = 2.8
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;
    for (final t in trazos) {
      if (t.length == 1) canvas.drawCircle(t.first, 1.4, lapiz);
      for (var i = 1; i < t.length; i++) {
        canvas.drawLine(t[i - 1], t[i], lapiz);
      }
    }
  }

  @override
  bool shouldRepaint(Firma old) => true;
}

// ---------------------------------------------------------------- Conflicto

class Conflicto extends StatelessWidget {
  const Conflicto({super.key, required this.visita});
  final Visita visita;

  static const campos = {
    'cobertura': 'Cobertura',
    'estado_conservacion': 'Estado',
    'presiones': 'Presiones',
    'cumple_compromisos': 'Cumple compromisos',
    'cumplimiento_detalle': 'Detalle',
    'hallazgos': 'Hallazgos',
    'recomendaciones': 'Recomendaciones',
    'firmante_nombre': 'Firmante',
  };

  String texto(Object? v) => v == null || v == ''
      ? '—'
      : v is bool
          ? (v ? 'Sí' : 'No')
          : v is List
              ? v.join(', ')
              : '$v';

  @override
  Widget build(BuildContext context) {
    final s = visita.servidor ?? {};
    final distintos = campos.keys.where((c) => texto(visita.datos[c]) != texto(s[c])).toList();
    Future<void> resolver(bool mia) async {
      await Datos.yo.resolverConflicto(visita, conservarMia: mia);
      if (context.mounted) Navigator.of(context).pop();
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Resolver conflicto')),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Esta visita cambió en la plataforma después de la última vez que tu teléfono la recibió. Compara y elige cuál versión queda. La otra no se pierde: queda en el historial del sistema.'),
        const SizedBox(height: 12),
        if (distintos.isEmpty) const Text('Los datos principales son iguales en ambas versiones.'),
        for (final c in distintos)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(campos[c]!, style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text('En tu teléfono: ${texto(visita.datos[c])}'),
                Text('En la plataforma: ${texto(s[c])}'),
              ]),
            ),
          ),
        const SizedBox(height: 16),
        FilledButton(onPressed: () => resolver(true), child: const Text('Conservar la de mi teléfono')),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: () => resolver(false), child: const Text('Usar la de la plataforma')),
      ]),
    );
  }
}

// ---------------------------------------------------------------- Predio nuevo

/// Alta de un predio levantado en campo. Queda en el teléfono y sube solo; después se puede delimitar su polígono.
class NuevoPredio extends StatefulWidget {
  const NuevoPredio({super.key});
  @override
  State<NuevoPredio> createState() => _NuevoPredioState();
}

class _NuevoPredioState extends State<NuevoPredio> {
  final llave = GlobalKey<FormState>();
  final nombre = TextEditingController();
  final vereda = TextEditingController();
  final municipio = TextEditingController();
  final departamento = TextEditingController(text: 'Boyacá');
  final fmi = TextEditingController();
  final area = TextEditingController();
  final ecosistema = TextEditingController();
  final observaciones = TextEditingController();
  bool guardando = false;

  Future<void> guardar() async {
    if (!llave.currentState!.validate()) return;
    setState(() => guardando = true);
    final ha = double.tryParse(area.text.trim().replaceAll(',', '.'));
    final predio = await Datos.yo.crearPredio({
      'nombre': nombre.text.trim(),
      'vereda': vereda.text.trim(),
      'municipio': municipio.text.trim(),
      'departamento': departamento.text.trim(),
      if (fmi.text.trim().isNotEmpty) 'fmi': fmi.text.trim(),
      if (ha != null) 'area_total_ha': ha,
      if (ecosistema.text.trim().isNotEmpty) 'ecosistema_estrategico': ecosistema.text.trim(),
      if (observaciones.text.trim().isNotEmpty) 'observaciones': observaciones.text.trim(),
    });
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Predio guardado. Ahora puedes delimitar su polígono en el mapa.')));
    Navigator.of(context).pop(predio);
  }

  @override
  Widget build(BuildContext context) {
    InputDecoration d(String t, {String? ayuda}) => InputDecoration(labelText: t, helperText: ayuda, border: const OutlineInputBorder());
    return Scaffold(
      appBar: AppBar(title: const Text('Nuevo predio')),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: FilledButton.icon(onPressed: guardando ? null : guardar, icon: const Icon(Icons.save), label: const Text('Guardar predio'), style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52))),
        ),
      ),
      body: Form(
        key: llave,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          const Text('Los datos que no sepas los completa la oficina después. Al guardar, el predio queda asignado a ti y podrás delimitar su polígono y registrar visitas.'),
          const SizedBox(height: 16),
          TextFormField(controller: nombre, textCapitalization: TextCapitalization.words, decoration: d('Nombre del predio *'), validator: (v) => (v ?? '').trim().isEmpty ? 'Escribe el nombre' : null),
          const SizedBox(height: 12),
          TextFormField(controller: municipio, textCapitalization: TextCapitalization.words, decoration: d('Municipio *'), validator: (v) => (v ?? '').trim().isEmpty ? 'Escribe el municipio' : null),
          const SizedBox(height: 12),
          TextFormField(controller: vereda, textCapitalization: TextCapitalization.words, decoration: d('Vereda')),
          const SizedBox(height: 12),
          TextFormField(controller: departamento, textCapitalization: TextCapitalization.words, decoration: d('Departamento')),
          const SizedBox(height: 12),
          TextFormField(
            controller: fmi,
            keyboardType: TextInputType.number,
            decoration: d('Matrícula inmobiliaria', ayuda: 'Ejemplo: 074-12345'),
            validator: (v) => (v ?? '').trim().isEmpty || RegExp(r'^[0-9]{3}-[0-9]{1,8}$').hasMatch(v!.trim()) ? null : 'Debe tener la forma 074-12345',
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: area,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: d('Área total (hectáreas)'),
            validator: (v) {
              if ((v ?? '').trim().isEmpty) return null;
              final n = double.tryParse(v!.trim().replaceAll(',', '.'));
              return n == null || n <= 0 ? 'Escribe un número mayor que cero' : null;
            },
          ),
          const SizedBox(height: 12),
          TextFormField(controller: ecosistema, textCapitalization: TextCapitalization.sentences, decoration: d('Ecosistema', ayuda: 'Ejemplo: páramo, bosque altoandino')),
          const SizedBox(height: 12),
          TextFormField(controller: observaciones, maxLines: 3, textCapitalization: TextCapitalization.sentences, decoration: d('Observaciones')),
        ]),
      ),
    );
  }
}
