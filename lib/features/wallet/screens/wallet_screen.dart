import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:voyage/core/theme/app_theme.dart';
import 'package:voyage/features/wallet/models/document_model.dart';
import 'package:voyage/features/wallet/providers/wallet_provider.dart';
import 'package:voyage/features/wallet/widgets/document_form_sheet.dart';
import 'package:voyage/features/wallet/widgets/hotel_doc_warnings.dart';

class WalletScreen extends ConsumerWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final docsAsync = ref.watch(documentsProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: const Text('Wallet', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: AppColors.surface,
        elevation: 0,
        bottom: PreferredSize(preferredSize: const Size.fromHeight(1), child: Container(color: AppColors.border, height: 1)),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => openDocumentFormSheet(context, ref),
        backgroundColor: AppColors.primary,
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: docsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Erreur : $e', style: TextStyle(color: AppColors.error))),
        data: (docs) => RefreshIndicator(
          onRefresh: () async {
            ref.invalidate(documentsProvider);
            await ref.read(documentsProvider.future);
          },
          child: docs.isEmpty
              ? ListView(children: const [
                  SizedBox(height: 80),
                  _EmptyState(),
                ])
              : ListView(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 100),
                  children: [
                    Text('MES DOCUMENTS', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.textSecondary, letterSpacing: 0.5)),
                    const SizedBox(height: 12),
                    for (final d in docs)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: DocumentCard(
                          doc: d,
                          onTap: () => openDocumentFormSheet(context, ref, existing: d),
                        ),
                      ),
                  ],
                ),
        ),
      ),
    );
  }
}

class DocumentCard extends ConsumerWidget {
  final TripDocument doc;
  final VoidCallback onTap;
  const DocumentCard({super.key, required this.doc, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          border: Border.all(color: AppColors.border),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 42, height: 42,
              decoration: BoxDecoration(color: AppColors.primaryLight, borderRadius: BorderRadius.circular(10)),
              child: Center(child: Text(categoryEmoji(doc.category), style: const TextStyle(fontSize: 20))),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(color: AppColors.primaryLight, borderRadius: BorderRadius.circular(4)),
                        child: Text(categoryLabel(doc.category), style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: AppColors.primary)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(doc.name, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textPrimary)),
                  if (doc.subtitle.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(doc.subtitle, style: TextStyle(fontSize: 11, color: AppColors.textSecondary), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ],
                  if (doc.reservationNumber != null) ...[
                    const SizedBox(height: 2),
                    Text('N° ${doc.reservationNumber}', style: TextStyle(fontSize: 10, color: AppColors.textSecondary, fontStyle: FontStyle.italic)),
                  ],
                  HotelDocWarnings(doc: doc, fontSize: 10),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: AppColors.textSecondary, size: 20),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        children: [
          Text('📁', style: TextStyle(fontSize: 56)),
          SizedBox(height: 16),
          Text('Aucun document pour l\'instant', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: AppColors.textPrimary)),
          SizedBox(height: 6),
          Text('Ajoute tes réservations d\'hôtel, billets de vol, tickets...\nColle un email de confirmation, je fais le reste.', textAlign: TextAlign.center, style: TextStyle(fontSize: 13, color: AppColors.textSecondary, height: 1.5)),
        ],
      ),
    );
  }
}
