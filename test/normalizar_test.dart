import 'package:flutter_test/flutter_test.dart';
import 'package:psa_campo/datos.dart';

void main() {
  group('Datos.normalizar', () {
    test('una IP de la red local va sin cifrar (http)', () {
      expect(Datos.normalizar('192.168.1.20:3210'), 'http://192.168.1.20:3210');
      expect(Datos.normalizar('10.0.2.2'), 'http://10.0.2.2');
    });

    test('localhost va sin cifrar', () {
      expect(Datos.normalizar('localhost:3210'), 'http://localhost:3210');
    });

    test('un dominio va por https', () {
      expect(Datos.normalizar('sistema-psa.ejemplo.com'), 'https://sistema-psa.ejemplo.com');
    });

    test('respeta el esquema escrito y quita la barra final', () {
      expect(Datos.normalizar('http://10.0.2.2:3299/'), 'http://10.0.2.2:3299');
      expect(Datos.normalizar('  https://sistema-psa.ejemplo.com//  '), 'https://sistema-psa.ejemplo.com');
    });

    test('un texto que solo parece IP no se toma como IP', () {
      expect(Datos.normalizar('1a2b3c4d'), 'https://1a2b3c4d');
    });

    test('vacío queda vacío', () {
      expect(Datos.normalizar('   '), '');
    });
  });
}
