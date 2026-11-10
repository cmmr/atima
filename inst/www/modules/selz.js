
import { $new_item_aes } from '/www/modules/aes.js';



//___________________________________________________________________
// Selectize.js with multi-select enabled.
//___________________________________________________________________

export function $new_selz_div (p) {

  if (p instanceof Array) return p.map($new_selz_div);
  
  const biom_key = p['biom_key'];

  _.defaults(p, {
    src: function () { return get_value(['BIOM', biom_key]) } });
  
  _.defaults(get_value(['SYNC', biom_key], {}), {
    selected: [], 
    palettes: { colors: 'classic', shapes: 'shapes', patterns: 'patterns' },
    mappings: { colors: {}, shapes: {}, patterns: {} } });

  const $selz_div = $('<div class="selz-div"/>');
  const $select   = $('<select multiple/>').appendTo($selz_div);

  $select.selectize({
    options     : [],
    items       : [],
    plugins     : ["drag_drop"],
    placeholder : "subset",
    onBlur      : plot_rebuild,
    onDelete    : selz_delete,
    onChange    : selz_change,
    render      : { item: selz_item_render }
  });

  if (p['id']) $selz_div.attr('id', p['id']);

  $selz_div
    .data(_.pick(p, ['biom_key', 'param', 'col_name', 'req', 'src', 'def', 'nonce', 'toggle']))
    .data('selz', $select.data('selectize'))
    .on('reload',  selz_div_reload)
    .on('sync',    selz_div_sync)
    .on('collect', selz_div_collect)
    .on('rm',      selz_div_rm);
  
  $selz_div.reload().sync();

  return $selz_div;
}


//___________________________________________________________________
// Update the options and default item(s).
//___________________________________________________________________
function selz_div_reload () {
  
  const $selz_div = $(this);
  const biom_key  = $selz_div.data('biom_key');
  const selz      = $selz_div.data('selz');
  const req       = $selz_div.data('req');
  const src       = $selz_div.data('src') || get_value(['BIOM', biom_key]);
  const def       = $selz_div.data('def') || [];
  const nonce     = $selz_div.data('nonce');
  
  const options       = (src instanceof Function) ? src() : src;
  const default_items = (def instanceof Function) ? def() : def;

  selz.clearOptions(true);
  selz.clearOptions(true); // once is not enough
  selz.refreshOptions(false);

  if (options && options.length > 0) {

    // Retain items selected prior to reload() call.
    const old_items = get_value(['SYNC', biom_key, 'selected']);
    let   new_items = _.intersection(old_items, options);
    if (new_items.length == 0)        new_items = default_items;
    if (new_items.length == 0 && req) new_items = _.slice(options, 0, 6);
    set_value(['SYNC', biom_key, 'selected'], new_items);

    // Repopulate all the options. Items will be re-populated in sync().
    selz.addOption(options.map(function (x) { return { value: x, text: x } }));
    selz.refreshOptions(false);
    
    // A hash of any dependencies requiring this selz to reload.
    if (nonce) $selz_div.data('nonce_val', nonce())
    
    // Listen for clicks on each item's "x".
    selz.$control.on('click', '.item-x', selz_item_x_click);

  }

}


//___________________________________________________________________
// Update the selected item(s).
//___________________________________________________________________
function selz_div_sync () {
  
  const $selz_div = $(this);
  const biom_key  = $selz_div.data('biom_key');
  const selz      = $selz_div.data('selz');
  const req       = $selz_div.data('req');
  const toggle    = $selz_div.data('toggle');
  const nonce     = $selz_div.data('nonce');
  const nonce_val = $selz_div.data('nonce_val');
  const $control  = $selz_div.closest('.control');
  let   aes_list  = $control.data('aes_list');
  
  // Reload or Hide as needed.
  //___________________________________________________________________
  if (nonce && nonce() !== nonce_val) $selz_div.reload().configure();
  if (toggle) $selz_div.toggleClass('d-none', !toggle());
  
  const selected = get_value(['SYNC', biom_key, 'selected']);
  const palettes = get_value(['SYNC', biom_key, 'palettes']);

  // Only replace items when needed.
  //___________________________________________________________________
  if (JSON.stringify(selz.getValue()) !== JSON.stringify(selected)) {
    selz.clear(true);
    selz.addItems(selected, true);
  }
  
  // Change [x] to (/) when last item is required.
  //___________________________________________________________________
  if (req) {
    const $el = selz.$control.find('.item-x');
    if (selected.length > 1) { $el.removeClass('fa-ban').addClass('fa-xmark'); }
    else                     { $el.removeClass('fa-xmark').addClass('fa-ban'); }
  }

  // Re-append aes popmenu(s) to each item.
  //___________________________________________________________________
  if (aes_list) {

    // For aes ending in _bool, check if that checkbox is selected.
    aes_list = aes_list
      .filter(aes => !aes.endsWith('_bool') || get_value(['SYNC', aes]))
      .map(aes => aes.replace('_bool', ''));

    selz.$control.children('.item').each(function (i, item) {
      
      const $item      = $(item);
      const biom_value = $item.data('value');
      
      $item.children('.item-flex').children('.item-aes').remove();
      const $item_x = $item.children('.item-flex').children('.item-x');
      
      aes_list.forEach(function (aes) {
        const pal_name = palettes[aes];
        $new_item_aes(biom_key, biom_value, pal_name).insertBefore($item_x);
      });

    });
  }

}


//___________________________________________________________________
// Compile subsetting or plotting arguments for rbiom.
//___________________________________________________________________
function selz_div_collect (e, result) {

  const $selz_div = $(this);

  if ($selz_div.is(':visible')) {

    const biom_key = $selz_div.data('biom_key');
    const col_name = $selz_div.data('col_name');
    const param    = $selz_div.data('param');
    const values   = get_value(['SYNC', biom_key, 'selected']);

    if (values.length > 0) {
      if (param) {
        result['plot_args'][param] = values;

      } else if (col_name) {
        result['subset_args']['cat'] ||= {};
        result['subset_args']['cat'][col_name] = values;
      }
    }

  }

}


//___________________________________________________________________
// Clean up nicely.
//___________________________________________________________________
function selz_div_rm () {
  const $selz_div = $(this);
  $selz_div.data('selz').destroy();
  $selz_div.empty();
}


//___________________________________________________________________
// Add 'x' next to items, and the container for .item-aes icons.
//___________________________________________________________________
function selz_item_render (item, escape) {
  const item_text = '<div class="item-text">' + escape(item['text']) + '</div>';
  const item_x    = '<div class="item-x fa-solid fa-xmark" title="Remove"></div>';
  return '<div class="item"><div class="item-flex">' + item_text + item_x + '</div></div>';
}


//___________________________________________________________________
// User clicked on the 'x' next to an item.
//___________________________________________________________________
function selz_item_x_click (e) {

	const $item     = $(e.currentTarget).closest('.item');
  const rm_item   = $item.data('value');
  const $selz_div = $item.closest('.selz-div');
  const selz      = $selz_div.data('selz');
  const biom_key  = $selz_div.data('biom_key');
  const req       = $selz_div.data('req');

  let items = get_value(['SYNC', biom_key, 'selected']);

  if (!req || items.length > 1) {

    items = _.difference(items, [rm_item]);
    set_value(['SYNC', biom_key, 'selected'], items);
    
    controls_sync();
    plot_rebuild();
  }
  
  selz.positionDropdown();

  return false;
}


//___________________________________________________________________
// Don't delete last item from a required input.
//___________________________________________________________________
function selz_delete () {
  const $selz_div = this.$input.closest('.selz-div');
  const req       = $selz_div.data('req');
  return (!req || this.getValue().length > 1);
}


//___________________________________________________________________
// Selectize is changed, but not deblurred yet.
//___________________________________________________________________
function selz_change (values) {

  const $selz_div = this.$input.closest('.selz-div');
  const biom_key  = $selz_div.data('biom_key');
  const req       = $selz_div.data('req');

  if (!req || values.length > 0) {

    const prior = get_value(['SYNC', biom_key, 'selected']);
    const old_n = prior.length;
    
    set_value(['SYNC', biom_key, 'selected'], values);

    // If re-ordering items, debounce immediately.
    if (old_n > 1 && old_n === values.length) plot_rebuild();
  }

  controls_sync();
  plot_rebuild();
}
