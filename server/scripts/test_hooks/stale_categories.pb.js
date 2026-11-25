// TEST FIXTURE ONLY. Mount into a disposable server; never ship in pb_hooks.
// Two loaded records reproduce the exact interleaving of parallel requests
// deterministically, without sleeps or weakening the production API rules.
routerAdd('POST', '/api/shopbandit-test/stale-category', (e) => {
  const body = e.requestInfo().body
  const app = e.app
  const stale = app.findFirstRecordByFilter('categories', 'id = {:id} && household = {:h}', {
    id: body.id, h: e.auth.getString('household'),
  })
  const deletion = app.findRecordById('categories', stale.id)
  if (body.operation === 'merge') {
    stale.set('name', 'Delayed rename')
    deletion.set('sort_order', 777)
    deletion.set('icon', 'eco')
    deletion.set('color', 'green')
    app.save(deletion)
    app.save(stale)
    return e.json(200, app.findRecordById('categories', stale.id).publicExport())
  }
  if (body.operation === 'sort') stale.set('sort_order', 321)
  else if (body.operation === 'restore') stale.set('deleted', false)
  else stale.set('name', 'Delayed rename')
  deletion.set('deleted', true)
  app.save(deletion)
  // original() on stale still says deleted=false even though SQL now says true.
  app.save(stale)
  return e.json(200, app.findRecordById('categories', stale.id).publicExport())
}, $apis.requireAuth('users'))

routerAdd('POST', '/api/shopbandit-test/stale-product', (e) => {
  const body = e.requestInfo().body
  const app = e.app
  const stale = app.findFirstRecordByFilter('catalog_items', 'id = {:id} && household = {:h}', {
    id: body.id, h: e.auth.getString('household'),
  })
  const current = app.findRecordById('catalog_items', stale.id)
  if (body.operation === 'delete') {
    const category = app.findRecordById('categories', stale.getString('category'))
    category.set('deleted', true)
    app.save(category)
  } else {
    current.set('category', require(`${__hooks}/categories.js`).categoryId(current.getString('household'), 'drinks'))
    current.set('category_manual', true)
    app.save(current)
  }
  stale.set('purchase_count', stale.getInt('purchase_count') + 1)
  app.save(stale)
  return e.json(200, app.findRecordById('catalog_items', stale.id).publicExport())
}, $apis.requireAuth('users'))
