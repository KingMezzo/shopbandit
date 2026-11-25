import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db.dart';
import '../l10n/app_localizations.dart';
import '../providers.dart';
import 'widgets.dart';

String categoryName(Category c, AppLocalizations t) {
  if (c.name.trim().isNotEmpty) return c.name;
  return switch (c.key) {
    'fruit_vegetables' => t.categoryFruitVegetables,
    'bakery' => t.categoryBakery,
    'dairy_eggs' => t.categoryDairyEggs,
    'meat' => t.categoryMeat,
    'fish' => t.categoryFish,
    'frozen' => t.categoryFrozen,
    'pantry' => t.categoryPantry,
    'canned' => t.categoryCanned,
    'drinks' => t.categoryDrinks,
    'snacks' => t.categorySnacks,
    'household' => t.categoryHousehold,
    _ => t.categoryOther,
  };
}

IconData categoryIcon(String icon) => switch (icon) {
  'eco' => Icons.eco_outlined,
  'bakery_dining' => Icons.bakery_dining_outlined,
  'egg_alt' => Icons.egg_alt_outlined,
  'restaurant' => Icons.restaurant_outlined,
  'set_meal' => Icons.set_meal_outlined,
  'ac_unit' => Icons.ac_unit,
  'kitchen' => Icons.kitchen_outlined,
  'inventory_2' => Icons.inventory_2_outlined,
  'local_drink' => Icons.local_drink_outlined,
  'cookie' => Icons.cookie_outlined,
  'cleaning_services' => Icons.cleaning_services_outlined,
  _ => Icons.category_outlined,
};

class CategoryBadge extends StatelessWidget {
  const CategoryBadge({super.key, required this.category});
  final Category category;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final accent = switch (category.color) {
      'green' => Colors.green,
      'brown' => Colors.brown,
      'amber' => Colors.amber,
      'red' => Colors.red,
      'cyan' => Colors.cyan,
      'blue' => Colors.blue,
      'orange' => Colors.orange,
      'teal' => Colors.teal,
      'indigo' => Colors.indigo,
      'purple' => Colors.purple,
      _ => scheme.primary,
    };
    return CircleAvatar(
      backgroundColor: accent.withValues(alpha: 0.12),
      foregroundColor: scheme.onSurfaceVariant,
      child: Icon(categoryIcon(category.icon), size: 22),
    );
  }
}

/// Uses the live category stream so a deleted category disappears even while
/// the product dialog is open. Selection is saved to the catalog immediately.
class ProductCategoryPicker extends ConsumerWidget {
  const ProductCategoryPicker({super.key, required this.itemId});
  final String itemId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final categories = ref.watch(categoriesProvider).value ?? const <Category>[];
    final items = ref.watch(catalogProvider).value ?? const <CatalogItem>[];
    final item = items.where((i) => i.id == itemId).firstOrNull;
    final selected = categories.where((c) => c.id == item?.category).firstOrNull;
    final t = context.t;
    return DropdownButtonFormField<String>(
      key: ValueKey(selected?.id),
      initialValue: selected?.id,
      isExpanded: true,
      decoration: InputDecoration(labelText: t.category),
      hint: Text(t.categoryOther),
      items: [
        for (final c in categories)
          DropdownMenuItem(
            value: c.id,
            child: Row(
              children: [
                Icon(categoryIcon(c.icon), size: 18),
                const SizedBox(width: 8),
                Expanded(child: Text(categoryName(c, t), overflow: TextOverflow.ellipsis)),
              ],
            ),
          ),
      ],
      onChanged: categories.isEmpty
          ? null
          : (id) async {
              if (id == null) return;
              try {
                await ref.read(sessionProvider).repo?.setCategory(itemId, id);
              } catch (e) {
                if (context.mounted) showError(context, e);
              }
            },
    );
  }
}

Future<void> editProductCategory(BuildContext context, CatalogItem item) => showDialog<void>(
  context: context,
  builder: (context) => AlertDialog(
    title: Text(item.name),
    content: SizedBox(width: 320, child: ProductCategoryPicker(itemId: item.id)),
    actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(context.t.close))],
  ),
);

/// Owns its controller until the dialog route finishes its exit animation.
class ProductEditDialog extends StatefulWidget {
  const ProductEditDialog({super.key, required this.item, required this.quantity});
  final CatalogItem item;
  final String quantity;

  @override
  State<ProductEditDialog> createState() => _ProductEditDialogState();
}

class _ProductEditDialogState extends State<ProductEditDialog> {
  late final _quantity = TextEditingController(text: widget.quantity);

  @override
  void dispose() {
    _quantity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = context.t;
    return AlertDialog(
      scrollable: true,
      title: Text(widget.item.name),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _quantity,
              autofocus: true,
              decoration: InputDecoration(labelText: t.quantity, hintText: t.quantityExample),
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
            const SizedBox(height: 16),
            ProductCategoryPicker(itemId: widget.item.id),
            const SizedBox(height: 8),
            Text(t.categoryAppliesToProduct, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(t.cancel)),
        FilledButton(onPressed: () => Navigator.pop(context, _quantity.text), child: Text(t.save)),
      ],
    );
  }
}
