// Model hooks also protect Admin Dashboard writes. All dependent writes use
// the event's transactional app, never the global app inside a transaction.
onRecordCreate((e) => {
  const originalApp = e.app
  try { originalApp.runInTransaction((tx) => {
    e.app = tx
    e.next()
    require(`${__hooks}/categories.js`).ensureDefaults(tx, e.record.id)
  }) } finally { e.app = originalApp }
}, 'households')

onRecordValidate((e) => {
  require(`${__hooks}/categories.js`).validateCategory(e.app, e.record)
  e.next()
}, 'categories')

onRecordUpdate((e) => {
  const originalApp = e.app
  try { originalApp.runInTransaction((tx) => {
    e.app = tx
    require(`${__hooks}/categories.js`).validateCategory(tx, e.record)
    // Move products before the tombstone, atomically with the category update.
    require(`${__hooks}/categories.js`).reassignDeleted(tx, e.record)
    e.next()
  }) } finally { e.app = originalApp }
}, 'categories')

onRecordDelete((e) => {
  // Keep tombstones for offline clients. Household cascade is allowed only
  // when its parent no longer exists (PocketBase deletes parent first).
  const parent = e.app.findRecordsByFilter('households', 'id = {:h}', '', 1, 0, { h: e.record.getString('household') })
  if (parent.length) throw new BadRequestError('category_use_soft_delete')
  e.next()
}, 'categories')

onRecordCreate((e) => {
  const originalApp = e.app
  try { originalApp.runInTransaction((tx) => {
    e.app = tx
    require(`${__hooks}/categories.js`).prepareCatalog(tx, e.record)
    e.next()
  }) } finally { e.app = originalApp }
}, 'catalog_items')

onRecordUpdate((e) => {
  const originalApp = e.app
  try { originalApp.runInTransaction((tx) => {
    e.app = tx
    require(`${__hooks}/categories.js`).prepareCatalog(tx, e.record)
    e.next()
  }) } finally { e.app = originalApp }
}, 'catalog_items')

// Explicit category changes through the regular API or Admin Dashboard are
// manual unless a new client explicitly identifies an automatic assignment.
onRecordUpdateRequest((e) => {
  const body = e.requestInfo().body
  if (body.category !== undefined && body.category_manual === undefined) {
    e.record.set('category_manual', true)
  }
  e.next()
}, 'catalog_items')

onRecordCreateRequest((e) => {
  const body = e.requestInfo().body
  if (body.category && body.category_manual === undefined) {
    e.record.set('category_manual', true)
  }
  e.next()
}, 'catalog_items')
