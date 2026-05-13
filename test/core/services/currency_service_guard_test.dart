import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:voyage/config/live_api_guards.dart';
import 'package:voyage/core/services/currency_service.dart';

void main() {
  group('CurrencyService live API guards', () {
    test('same-currency lookup returns 1.0 without live permission', () async {
      final service = CurrencyService(guards: LiveApiGuards.defaults());

      expect(await service.getRate('EUR', 'eur'), 1.0);
    });

    test('exchange rate lookup blocks by default before HTTP', () async {
      final client = _FakeCurrencyHttpClient();
      final service = CurrencyService(
        guards: LiveApiGuards.defaults(),
        httpClient: client,
      );

      await expectLater(
        service.getRate('USD', 'EUR'),
        throwsA(
          isA<LiveApiBlockedException>()
              .having((e) => e.family, 'family', LiveApiFamily.currencyApi)
              .having(
                (e) => e.operation,
                'operation',
                'CurrencyService.getRate exchange rates',
              )
              .having((e) => e.message, 'message', contains('Currency API'))
              .having(
                (e) => e.message,
                'message',
                contains('CurrencyService.getRate exchange rates'),
              )
              .having(
                (e) => e.message,
                'message',
                contains('--dart-define=ALLOW_LIVE_CURRENCY_API=true'),
              ),
        ),
      );
      expect(client.sentRequests, isZero);
    });

    test('allowed lookup reaches injected offline HTTP client', () async {
      final client = _FakeCurrencyHttpClient(rate: 0.92);
      final service = CurrencyService(
        guards: const LiveApiGuards(allowCurrencyApi: true),
        httpClient: client,
      );

      expect(await service.getRate('USD', 'EUR'), 0.92);
      expect(client.sentRequests, 1);

      expect(await service.getRate('USD', 'EUR'), 0.92);
      expect(client.sentRequests, 1, reason: 'second lookup should use cache');
    });
  });
}

class _FakeCurrencyHttpClient extends http.BaseClient {
  final double rate;
  int sentRequests = 0;

  _FakeCurrencyHttpClient({this.rate = 1.0});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sentRequests++;
    final body = jsonEncode({
      'rates': {'EUR': rate},
    });
    return http.StreamedResponse(
      Stream<List<int>>.value(utf8.encode(body)),
      200,
    );
  }
}
