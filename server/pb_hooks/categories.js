const data = require('./category_data.js')

function categoryId(household, key) {
  return $security.sha256(household + '|category|' + key).slice(0, 15)
}

function normalize(name) {
  return String(name).toLowerCase().replace(/ä/g, 'ae').replace(/ö/g, 'oe')
    .replace(/ü/g, 'ue').replace(/ß/g, 'ss').replace(/[éè]/g, 'e')
    .replace(/[\s\-]+/g, ' ').trim()
}

function classify(name) { return data.words[normalize(name)] || 'other' }

// Idempotent, runs within the household/catalog transaction. Existing names,
// ordering and tombstones are never reset by bootstrap.
function ensureDefaults(app, household) {
  const existing = app.findRecordsByFilter('categories', 'household = {:h}', '', 0, 0, { h: household })
  const keys = {}
  for (const c of existing) keys[c.getString('key')] = true
  const collection = app.findCollectionByNameOrId('categories')
  data.defaults.forEach((d, i) => {
    if (keys[d.key]) return
    const c = new Record(collection)
    c.set('id', categoryId(household, d.key))
    c.set('household', household)
    c.set('key', d.key)
    c.set('is_default', true)
    c.set('sort_order', i * 10)
    c.set('icon', d.icon)
    c.set('color', d.color)
    app.save(c)
  })
}

function validateCategory(app, record) {
  const original = record.original()
  const key = record.getString('key')
  const isDefault = data.defaults.some((d) => d.key === key)
  if (!record.isNew() && (original.getString('household') !== record.getString('household') ||
      original.getString('key') !== key || original.getBool('is_default') !== record.getBool('is_default'))) {
    throw new BadRequestError('category_identity_immutable')
  }
  if (isDefault !== record.getBool('is_default') ||
      (isDefault && record.id !== categoryId(record.getString('household'), key))) {
    throw new BadRequestError('category_identity_invalid')
  }
  if (isDefault && record.getBool('deleted')) throw new BadRequestError('category_default_protected')
  if (!isDefault && !record.getString('name').trim()) throw new BadRequestError('category_name_required')
  if (!record.isNew() && original.getBool('deleted') && !record.getBool('deleted')) {
    // Deletion wins over a stale rename/create retry from an offline device.
    throw new BadRequestError('category_deleted')
  }
}

// PocketBase loads PATCH records before our write transaction and saves all
// fields. original() is that request's snapshot, NOT the current SQL row.
// Merge only changed fields onto the row read while holding the writer lock.
function prepareCategoryUpdate(app, record) {
  validateCategory(app, record)
  const snapshot = record.original()
  const current = app.findRecordById('categories', record.id)
  for (const field of ['name', 'sort_order', 'icon', 'color']) {
    if (record.get(field) === snapshot.get(field)) record.set(field, current.get(field))
  }
  // An update based on an active snapshot may arrive after a deletion. Retain
  // the tombstone even if that old snapshot explicitly contained deleted=false.
  // Explicit restores based on a deleted snapshot are still rejected above.
  if (current.getBool('deleted')) record.set('deleted', true)
}

function prepareCatalog(app, record) {
  const hid = record.getString('household')
  ensureDefaults(app, hid)
  const snapshot = record.original()
  const current = record.isNew() ? null : app.findRecordById('catalog_items', record.id)
  if (current && ['category', 'category_manual', 'category_version'].every((field) => record.get(field) === snapshot.get(field))) {
    for (const field of ['category', 'category_manual', 'category_version']) record.set(field, current.get(field))
  }
  if (current && current.getBool('category_manual') && !record.getBool('category_manual')) {
    record.set('category', current.getString('category'))
    record.set('category_manual', true)
  }
  if (!record.getString('category') || (!record.getBool('category_manual') && record.getInt('category_version') < 1)) {
    record.set('category', categoryId(hid, classify(record.getString('name'))))
  }
  const c = app.findRecordById('categories', record.getString('category'))
  if (c.getString('household') !== hid) throw new BadRequestError('category_foreign_household')
  if (c.getBool('deleted')) {
    record.set('category', categoryId(hid, 'other'))
    record.set('category_manual', true)
  }
  record.set('category_version', 1)
}

function reassignDeleted(app, record) {
  if (!record.getBool('deleted')) return
  const hid = record.getString('household')
  const other = categoryId(hid, 'other')
  for (const item of app.findRecordsByFilter('catalog_items', 'household = {:h} && category = {:c}', '', 0, 0, { h: hid, c: record.id })) {
    item.set('category', other)
    // This deliberate reassignment must never be auto-categorized again.
    item.set('category_manual', true)
    app.save(item)
  }
}

module.exports = { categoryId, classify, ensureDefaults, validateCategory, prepareCategoryUpdate, prepareCatalog, reassignDeleted }
