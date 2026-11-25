import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'product_dictionary.dart';

const defaultCategoryKeys = [
  'fruit_vegetables',
  'bakery',
  'dairy_eggs',
  'meat',
  'fish',
  'frozen',
  'pantry',
  'canned',
  'drinks',
  'snacks',
  'household',
  'other',
];

const defaultCategoryIcons = [
  'eco',
  'bakery_dining',
  'egg_alt',
  'restaurant',
  'set_meal',
  'ac_unit',
  'kitchen',
  'inventory_2',
  'local_drink',
  'cookie',
  'cleaning_services',
  'category',
];

const defaultCategoryColors = [
  'green',
  'brown',
  'amber',
  'red',
  'cyan',
  'blue',
  'orange',
  'teal',
  'indigo',
  'purple',
  'grey',
  'grey',
];

/// Same 15-character PocketBase ID on the server and every offline device.
String categoryId(String household, String key) =>
    sha256.convert(utf8.encode('$household|category|$key')).toString().substring(0, 15);

String normalizeProduct(String name) => name
    .toLowerCase()
    .replaceAll('ä', 'ae')
    .replaceAll('ö', 'oe')
    .replaceAll('ü', 'ue')
    .replaceAll('ß', 'ss')
    .replaceAll('é', 'e')
    .replaceAll('è', 'e')
    .replaceAll(RegExp(r'[\s\-]+'), ' ')
    .trim();

/// Only explicit whole-name synonyms are accepted. Never guesses substrings.
String categorizeProduct(String name) => productDictionary[normalizeProduct(name)] ?? 'other';
