
export function aes_init () {

  $('<div id="aes_popmenu"/>')
    .appendTo($('html'))
    .css({
      'display'         : 'none',
      'flex-wrap'       : 'wrap',
      'justify-content' : 'center',
      'position'        : 'fixed',
      'min-width'       : '170px',
      'max-width'       : '200px',
      'overflow'        : 'auto',
      'z-index'         : '3' });

  // Will be arranged around the active element.
  $('html')
    .append(['t', 'r', 'b', 'l', 'c'].map(
      function (id) {
        return $('<div/>')
          .attr('id', 'aes_popmenu_overlay_' + id)
          .addClass('aes-popmenu-overlay')
          .css({
            'display'    : 'none',
            'position'   : 'fixed',
            'z-index'    : '2',
            'background' : '#000000AA' })
          .on('click', aes_popmenu_hide);
      }));
  $('#aes_popmenu_overlay_c')
    .css({
      'background' : 'transparent',
      'cursor'     : 'pointer' });

}


//___________________________________________________________________
// get_aes_mapping(['col_options', 'Sex'], 'vibrant')
//   => { Male: '#EE7733', Female: '#0077BB' }
//___________________________________________________________________
function get_aes_mapping (biom_key, pal_name) {

  const biom_options = get_value(['BIOM', biom_key]);
  const aes_options  = get_value(['CONF', 'aes_options', pal_name]);
  
  // Stored as index of the option, so updating options will work.
  biom_options.forEach(function (opt_value, opt_index) {
    const i = opt_index % aes_options.length;
    default_value(['SYNC', biom_key, 'mappings', pal_name, opt_value], i);
  });

  // Return the current value of each option.
  let aes_mapping = get_value(['SYNC', biom_key, 'mappings', pal_name]);
      aes_mapping = _.mapValues(aes_mapping, function(i) { return aes_options[i]; });

  return aes_mapping;
}


function set_aes_mapping (biom_key, pal_name, biom_val, new_aes_value) {

  const aes_options = get_value(['CONF', 'aes_options', pal_name]);
  const i           = _.indexOf(aes_options, new_aes_value);

  set_value(['SYNC', biom_key, 'mappings', pal_name, biom_val], i);
}


export function aes_plot_args (aes, biom_key) {
  
  const selected = get_value(['SYNC', biom_key, 'selected']) || [];
  const pal_name = get_value(['SYNC', biom_key, 'palettes', aes]);

  let plot_args = true;

  if (selected.length > 0) {

    const aes_mapping = get_aes_mapping(biom_key, pal_name);
    plot_args = selected.map((x) => aes_mapping[x]);
    
  } else if (aes === 'colors') {

    if (pal_name === 'custom') {
      const biom_options  = get_value(['BIOM', biom_key]);
      const custom_colors = get_value(['CONF', 'aes_options', 'custom']);
      plot_args = _.slice(custom_colors, 0, biom_options.length);

    } else {
      plot_args = pal_name;
    }

  }
  
  return plot_args;
}




// biom_key: ['col_options', 'Body Site']
// biom_val: 'Saliva'
export function $new_item_aes (biom_key, biom_val, pal_name) {
  
  const aes_mapping = get_aes_mapping(biom_key, pal_name);
  const aes_options = get_value(['CONF', 'aes_options', pal_name]);
  const aes_value   = aes_mapping[biom_val];

  return $new_aes_icon(pal_name, aes_value)
    .addClass('item-aes')
    .data('value',    aes_value)
    .data('options',  aes_options)
    .data('biom_key', biom_key)
    .data('biom_val', biom_val)
    .data('pal_name', pal_name)
    .on('click',  aes_popmenu_show)
    .on('change', item_aes_change);
  
}

export function $new_aes_icon (pal_name, aes_value) {
  
  if (['shapes', 'patterns'].includes(pal_name)) { // A shape or pattern
    return $('<img class="aes-icon"/>').attr('src', '/www/img/aes/' + aes_value + '.png');
  } else { // A single color
    return $('<div class="aes-icon"/>').css('background', aes_value);
  }
}

function item_aes_change (e, new_aes_value) {

  const $item_aes = $(this);
  const biom_key  = $item_aes.data('biom_key');
  const pal_name  = $item_aes.data('pal_name');
  const biom_val  = $item_aes.data('biom_val');

  set_aes_mapping(biom_key, pal_name, biom_val, new_aes_value);
  $item_aes.data('value', new_aes_value);

  if (['shapes', 'patterns'].includes(pal_name)) {
    $item_aes.attr('src', '/www/img/aes/' + new_aes_value + '.png');
  } else {
    $item_aes.css('background', new_aes_value);
  }

  plot_rebuild();
}



function $new_palette_control (p) {
  if (p instanceof Array) return p.map($new_palette_control);
  return $new_control()
    .append($new_control_row(p, 'major-row palette-row').append($new_palette(p)));
}

export function $new_palette_minor_row (p) {
  _.defaults(p, { label: 'palette' });
  return $new_control_row(p, 'minor-row palette-row')
    .append($new_palette(p))
    .append([0,1,2,3,4,5,6].map($new_swatch))
    .append($new_palette_toggle());
}


function $new_palette (p) {
  
  _.defaults(p, { sync_id: p['id'], pal_type: 'cat', value: null, options: null});

  return $new_palette_icon()
    .addClass('palette')
    .data(_.pick(p, ['sync_id', 'param', 'pal_type', 'def', 'value', 'options']))
    .on('click',   aes_popmenu_show)
    .on('change',  palette_change)
    .on('sync',    palette_sync)
    .on('collect', palette_collect);
}


function palette_collect (e, result) {

  const $palette = $(this);
  const sync_id  = $palette.data('sync_id');
  const param    = $palette.data('param');

  if (param && $palette.closest('.control-row').is(':visible')) {

    const pal_name = get_value(['SYNC', sync_id]);

    if (pal_name === 'custom') {
      const custom_colors = get_value(['CONF', 'aes_options', 'custom']);
      result['plot_args'][param] = custom_colors;
    } else {
      result['plot_args'][param] = pal_name;
    }
    
  }
}


function palette_change (e, new_pal_name) {
  
  const $palette = $(this);
  const sync_id  = $palette.data('sync_id');

  set_value(['SYNC', sync_id], new_pal_name);
  
  $palette.closest('.control').sync();
  plot_rebuild();
}


function palette_sync () {

  const $palette = $(this);
  const sync_id  = $palette.data('sync_id');
  const pal_type = $palette.data('pal_type');
  const def      = $palette.data('def');

  const pal_options = get_value(['CONF', 'palette_options', 'colors', pal_type]);
  const pal_value   = get_value(['SYNC', sync_id], def || pal_options[0]);
  
  $palette
    .data('value',   pal_value)
    .data('options', pal_options)
    .attr('src', '/www/img/aes/' + pal_value + '.png');
}




// A set of colors or gradient displayed with a pre-rendered image.
export function $new_palette_icon (pal_value) {

  const $palette_icon = $('<img class="palette-icon">');

  if (pal_value)
    $palette_icon.attr('src', '/www/img/aes/' + pal_value + '.png');

  return $palette_icon;
}



function $new_swatch (i) {
  return $('<input type="color" class="swatch">')
    .data('i', i)
    .on('sync',   swatch_sync)
    .on('change', swatch_change);
}

function swatch_sync () {
  this.value = get_value(['CONF', 'aes_options', 'custom', $(this).data('i')]);
}

function swatch_change () {
  set_value(['CONF', 'aes_options', 'custom', $(this).data('i')], this.value);
  controls_sync();
  plot_rebuild();
}


function $new_palette_toggle () {
  return $('<div class="palette-toggle"/>')
    .on('click', function () {

      const $palette_row = $(this).closest('.palette-row');
      const $palette     = $palette_row.children('.palette');

      $palette_row.toggleClass('custom');

      if ($palette_row.hasClass('custom')) {
        $palette.triggerHandler('change', ['custom']);
      } else {
        $palette.triggerHandler('change', [$palette.data('pal_value')]);
      }
      
      
    })
}









function aes_popmenu_select () {
  
  const option   = $(this).data('option');
  const $aes_popmenu = $('#aes_popmenu');
  const $icon    = $aes_popmenu.data('$icon');
  
  if ($icon.data('value') !== option) {
    $icon.data('value', option);
    $icon.triggerHandler('change', [option]);
  }
  
  aes_popmenu_hide();
}



export function aes_popmenu_hide () {
  $('#aes_popmenu').empty().hide();
  $('.aes-popmenu-overlay').hide();
}



function aes_popmenu_show () {
  
  const $icon    = $(this);
  const $aes_popmenu = $('#aes_popmenu');
  const options  = $icon.data('options');
  
  // Gray out everything except for the <img>'s parent.
  // Clicking on the img's parent or anywhere other than
  // #aes_popmenu will hide #aes_popmenu and not change any aes.
  const $item = $icon.parent(); // usually an .item but not necessarily.
  
  const x1 = $item.offset().left;
  const y1 = $item.offset().top;
  const x2 = x1 + $item.outerWidth();
  const y2 = y1 + $item.outerHeight();
  
  $('#aes_popmenu_overlay_t').css({
    'top'    : 0, 
    'left'   : 0, 
    'width'  : '100vw', 
    'height' : y1 + 'px' });
    
  $('#aes_popmenu_overlay_l').css({
    'top'    : y1 + 'px',
    'left'   : 0,
    'width'  : x1 + 'px',
    'height' : (y2 - y1) + 'px' });
    
  $('#aes_popmenu_overlay_b').css({
    'top'    : y2 + 'px',
    'left'   : 0,
    'width'  : '100vw',
    'height' : 'calc(100vh - ' + y2 + 'px)' });
    
  $('#aes_popmenu_overlay_r').css({
    'top'    : y1 + 'px',
    'left'   : x2 + 'px',
    'width'  : 'calc(100vw - ' + x2 + 'px)',
    'height' : (y2 - y1) + 'px' });
    
  $('#aes_popmenu_overlay_c').css({
    'top'    : y1 + 'px',
    'left'   : x1 + 'px',
    'width'  : (x2 - x1) + 'px',
    'height' : (y2 - y1) + 'px' });
    
  $('.aes-popmenu-overlay').show();
  
  
  $aes_popmenu
    .data('$icon', $icon)
    .empty()
    .css('display', 'flex');
    
  if ($icon.hasClass('aes-icon')) {
    
    const pal_name = $icon.data('pal_name');

    $aes_popmenu
      .addClass('aes-options')
      .removeClass('pal-options')
      .append(options.map(function (option) {
        return $new_aes_icon(pal_name, option)
          .data('option', option)
          .on('click', aes_popmenu_select);
      }));
    
  } else if ($icon.hasClass('palette-icon')) {
    $aes_popmenu
      .addClass('pal-options')
      .removeClass('aes-options')
      .append(options.map(function (option) {
        return $new_palette_icon(option)
          .data('option', option)
          .on('click', aes_popmenu_select);
      }));
  }
  
  const vw = Math.max(document.documentElement.clientWidth  || 0, window.innerWidth  || 0);
  const pw = $aes_popmenu.width();
  const x  = Math.min(($icon.offset().left + ($icon.width() / 2) - (pw / 2)), vw - pw - 5);
  const y  = $icon.offset().top + $icon.height() + 10;
  $aes_popmenu
    .css({
      'left' : Math.round(x) + 'px', 
      'top'  : Math.round(y) + 'px' });
}




