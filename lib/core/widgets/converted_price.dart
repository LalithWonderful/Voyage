import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/providers/currency_provider.dart';

/// Texte inline qui affiche un prix avec conversion dans la devise de l'utilisateur.
/// Ex : "~800 THB (~20€)"
class ConvertedPriceText extends ConsumerWidget {
  final String? rawPrice;
  final TextStyle? style;
  final String prefix;
  final int maxLines;
  final TextOverflow overflow;

  const ConvertedPriceText({
    super.key,
    required this.rawPrice,
    this.style,
    this.prefix = '',
    this.maxLines = 1,
    this.overflow = TextOverflow.ellipsis,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (rawPrice == null || rawPrice!.isEmpty) return const SizedBox.shrink();
    final async = ref.watch(convertedPriceProvider(rawPrice));
    final text = async.valueOrNull ?? rawPrice!;
    return Text(
      '$prefix$text',
      style: style,
      maxLines: maxLines,
      overflow: overflow,
    );
  }
}

/// Pill (badge rond) avec un prix converti. Remplace les "_Pill('💰 ...')" manuels.
class ConvertedPricePill extends ConsumerWidget {
  final String? rawPrice;
  final Color color;
  final Color bg;
  final double fontSize;
  final String prefix;

  const ConvertedPricePill({
    super.key,
    required this.rawPrice,
    required this.color,
    required this.bg,
    this.fontSize = 9,
    this.prefix = '💰 ',
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (rawPrice == null || rawPrice!.isEmpty) return const SizedBox.shrink();
    final async = ref.watch(convertedPriceProvider(rawPrice));
    final text = async.valueOrNull ?? rawPrice!;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(4)),
      child: Text(
        '$prefix$text',
        style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }
}
