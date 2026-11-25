import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db.dart';
import '../providers.dart';
import 'category_widgets.dart';
import 'household_screen.dart' show confirm;
import 'widgets.dart';

class CategoriesScreen extends ConsumerWidget {
  const CategoriesScreen({super.key});

  Future<void> _edit(BuildContext context, WidgetRef ref, [Category? category]) async {
    final t = context.t;
    final repo = ref.read(sessionProvider).repo;
    final name = await showDialog<String>(
      context: context,
      builder: (context) => _CategoryNameDialog(
        initial: category == null ? '' : categoryName(category, t),
        title: category == null ? t.createCategory : t.renameCategory,
      ),
    );
    if (name == null) return;
    try {
      if (category == null) {
        await repo?.createCategory(name);
      } else {
        await repo?.renameCategory(category.id, name);
      }
    } catch (e) {
      if (context.mounted) showError(context, e);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = context.t;
    final categories = ref.watch(categoriesProvider).value ?? const <Category>[];
    final catalog = ref.watch(catalogProvider).value ?? const <CatalogItem>[];
    final repo = ref.watch(sessionProvider.select((s) => s.repo));
    final counts = <String, int>{};
    for (final item in catalog) {
      counts.update(item.category, (n) => n + 1, ifAbsent: () => 1);
    }
    return Scaffold(
      appBar: GradientAppBar(title: Text(t.manageCategories), actions: const [SyncIndicator()]),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _edit(context, ref),
        icon: const Icon(Icons.add),
        label: Text(t.createCategory),
      ),
      body: Column(
        children: [
          Padding(padding: const EdgeInsets.all(16), child: Text(t.categoriesHint)),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.only(bottom: 96),
              itemCount: categories.length,
              onReorderItem: (oldIndex, newIndex) async {
                final ids = categories.map((c) => c.id).toList();
                ids.insert(newIndex, ids.removeAt(oldIndex));
                try {
                  await repo?.reorderCategories(ids);
                } catch (e) {
                  if (context.mounted) showError(context, e);
                }
              },
              itemBuilder: (context, i) {
                final c = categories[i];
                final name = categoryName(c, t);
                return ListTile(
                  key: ValueKey(c.id),
                  leading: CategoryBadge(category: c),
                  title: Text(name),
                  subtitle: Text('${t.listCount(counts[c.id] ?? 0)}${c.isDefault ? ' · ${t.defaultCategory}' : ''}'),
                  onTap: () => _edit(context, ref, c),
                  trailing: Padding(
                    padding: const EdgeInsets.only(right: 24),
                    child: PopupMenuButton<String>(
                      tooltip: t.categoryActions,
                      onSelected: (action) async {
                        try {
                          if (action == 'rename') {
                            await _edit(context, ref, c);
                          }
                          if (action == 'reset') {
                            await repo?.renameCategory(c.id, '');
                          }
                          if (action == 'delete') {
                            if (!context.mounted) return;
                            final ok = await confirm(
                              context,
                              title: t.deleteNamed(name),
                              message: t.deleteCategoryMessage,
                              action: t.delete,
                            );
                            if (ok) await repo?.deleteCategory(c.id);
                          }
                          if (action == 'up' || action == 'down') {
                            final ids = categories.map((c) => c.id).toList();
                            final target = action == 'up' ? i - 1 : i + 1;
                            ids.insert(target, ids.removeAt(i));
                            await repo?.reorderCategories(ids);
                          }
                        } catch (e) {
                          if (context.mounted) showError(context, e);
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(value: 'rename', child: Text(t.renameCategory)),
                        if (c.isDefault && c.name.isNotEmpty)
                          PopupMenuItem(value: 'reset', child: Text(t.resetCategoryName)),
                        if (i > 0) PopupMenuItem(value: 'up', child: Text(t.moveUp)),
                        if (i < categories.length - 1) PopupMenuItem(value: 'down', child: Text(t.moveDown)),
                        if (!c.isDefault) PopupMenuItem(value: 'delete', child: Text(t.delete)),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryNameDialog extends StatefulWidget {
  const _CategoryNameDialog({required this.initial, required this.title});
  final String initial;
  final String title;

  @override
  State<_CategoryNameDialog> createState() => _CategoryNameDialogState();
}

class _CategoryNameDialogState extends State<_CategoryNameDialog> {
  late final _name = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: TextField(
        controller: _name,
        autofocus: true,
        maxLength: 80,
        textCapitalization: TextCapitalization.sentences,
        decoration: InputDecoration(labelText: t.categoryName),
        onSubmitted: (v) {
          if (v.trim().isNotEmpty) Navigator.pop(context, v);
        },
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.cancel)),
        ValueListenableBuilder<TextEditingValue>(
          valueListenable: _name,
          builder: (context, value, _) => FilledButton(
            onPressed: value.text.trim().isEmpty ? null : () => Navigator.pop(context, _name.text),
            child: Text(t.save),
          ),
        ),
      ],
    );
  }
}
