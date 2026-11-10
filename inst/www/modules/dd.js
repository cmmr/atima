
import { $new_palette_minor_row } from '/www/modules/aes.js';


export function dd_init () {

  //___________________________________________________________________
  // Metrics
  //___________________________________________________________________

  $new_dd_control([
    { id: 'adiv_metric', label: 'y-Axis',     param: 'adiv', src: 'adiv_options' },
    { id: 'dist_metric', label: 'Metric',     param: 'dist', src: 'dist_options' },
    { id: 'bdor_metric', label: 'Ordination', param: 'ord',  src: 'ord_options'  },
    { id: 'bdiv_metric', label: 'Metric',     param: 'bdiv', src: 'bdiv_options' }
  ]);


  //___________________________________________________________________
  // Rarefaction depth.
  //___________________________________________________________________

  $new_dd_control({
    id    : 'rare_depth',
    param : 'rline',
    label : 'Depth',
    src   : 'depth_options',
    def   : function () { return get_value(['BIOM', 'depth']); } })

  .append(
    $('<div>Changes will affect all pages.</div>')
      .css({
        'color'            : 'lightgrey',
        'font-size'        : '11px',
        'background-color' : '#1d3d7c',
        'font-style'       : 'italic',
        'font-weight'      : 'bold',
        'padding'          : '0 0 5px 5px' }))

  .on('configure', function () {
    set_value(['SYNC', 'rare_depth'], get_value(['BIOM', 'depth'])); })

  .find('select.dd')
  .off('change').on('change', function () {
    
    const new_depth = Number($(this).val());
    const old_depth = get_value(['BIOM', 'depth']);

    // Reload the project with new rarefaction depth.
    if (new_depth != old_depth) {
      api({
        'method'      : 'rarefy', 
        'spinner_msg' : 'Rarefying to ' + new_depth + ' reads per sample.', 
        'payload'     : { depth: new_depth },
        'onError'     : function () { $('#rare_depth').configure().sync(); } });
    }
  });


  //___________________________________________________________________
  // Heatmap grid controls.
  //___________________________________________________________________

  $new_control()

    .append($new_collapsible_control_row({ id: 'hm_grid', label: 'Grid', class: 'major-row' }))

    .append($new_palette_minor_row({
        param    : 'grid',
        pal_type : 'num',
        sync_id  : function () { return get_value(['CONF', 'nav_page']) + '_grid';                    },
        def      : function () { return get_value(['CONF', 'nav_page']) === 'bdiv' ? 'bam' : 'acton'; }
      }))

    .append($new_dd_minor_row({
        id    : 'hm_rescale',
        param : 'rescale',
        label : 'normalize',
        src   : { none: 'none', rows: 'rows', columns: 'cols' }
      })
      .on('configure', function () {
        $(this).toggleClass('d-none', get_value(['CONF', 'nav_page']) !== 'tahm');
      }))

    .append($new_dd_minor_row({ id: 'hm_clust', param: 'clust', label: 'clustering', src: 'clust_options' }))
    .append($new_dd_minor_row({ id: 'hm_dist',  param: 'dist',  label: 'distance',   src: 'dist_options' }));


  $new_control()

    .append($new_collapsible_control_row({ id: 'hm_margins', label: 'Margins', class: 'major-row' }))

    .append($new_dd_minor_row({
        id    : 'hm_trees',
        param : 'trees',
        label : 'trees',
        src   : { 'rows & columns': 'both', 'rows only': 'left', 'columns only': 'top', 'none': 'none' }
      }))

    .append($new_dd_minor_row({
        id    : 'hm_label',
        param : 'label',
        label : 'label',
        src   : { 'rows & columns': 'both', 'rows only': 'rows', 'columns only': 'cols', 'none': 'none' }
      }))

    .append($new_dd_minor_row({
        id    : 'hm_xlab_angle',
        param : 'xlab.angle',
        label : 'x-label angle',
        src   : { autoselect: 'auto', horizontal: 0, angled: 30, vertical: 90 }
      })
      .on('sync', function () {
        $(this).toggleClass('d-none', !['both', 'cols'].includes(get_value(['SYNC', 'hm_label'])));
      }));

}


function $new_collapsible_control_row (p, cls) {
  return $new_control_row(p, cls)
    .append($('<div class="control-toggle"/>'))
    .on('click', function () { $(this).closest('.control').toggleClass('collapsed'); })
}


//___________________________________________________________________
// Simple <select> dropdown menus.
//___________________________________________________________________

export function $new_dd_control (p) {

  if (p instanceof Array) return p.map($new_dd_control);

  return $new_control()
    .append($new_dd_major_row(p));
}

export function $new_dd_major_row (p) {

  if (p instanceof Array) return p.map($new_dd_major_row);

  _.defaults(p, { sync_id: p['id'], param: guess_param(p) });

  return $new_control_row(p, 'major-row dd-row')
    .append($new_dd(p))
    .append($new_dd_x(p))
    .on('sync', dd_major_row_sync);
}

export function $new_dd_minor_row (p) {

  if (p instanceof Array) return p.map($new_dd_minor_row);

  _.defaults(p, { sync_id: p['id'], param: guess_param(p) });

  return $new_control_row(p, 'minor-row dd-row')
    .append($new_dd(p));
}



//___________________________________________________________________
// Toggle the control's `active` class based on selection.
//___________________________________________________________________
function dd_major_row_sync () {
  
  const $major_row = $(this);

  if ($major_row.is(':visible')) {

    const $control = $major_row.closest('.control');
    const sync_id  = $major_row.closest('.control-row').data('sync_id');
    const selected = get_value(['SYNC', sync_id]);

    $control.toggleClass('active', (selected !== null && selected !== undefined))
  }
}




//___________________________________________________________________
// A <select> dropdown menu.
//___________________________________________________________________
function $new_dd (p) {
  
  if (p instanceof Array) return p.map($new_dd);

  const multi = (p['multi'] === true);
  const theme = p['theme'] || 'lime';

  _.defaults(p, {
    req: (multi === false),
    src: { Yes: true, No: false } });

  const $dd = $('<select class="dd"/>')
    .data(_.pick(p, ['req', 'src', 'def']))
    .addClass('dd-' + theme)
    .addClass(multi ? 'dd-multi' : 'dd-single')
    .on('reload',  multi ? dd_multi_reload : dd_single_reload)
    .on('sync',    multi ? dd_multi_sync   : dd_single_sync)
    .on('change',  multi ? dd_multi_change : dd_single_change)
    .on('collect', dd_collect);

  return $dd;
}



function new_dd_options (src) {

  if (src instanceof Function) src = src();
  if (typeof src === 'string') src = get_value(['BIOM', src]);
    
  if (src instanceof Array) {
    return src.map(function (o) {
      const $option = $('<option/>').text(o);
      if (typeof o !== 'string') $option.data('value', o);
      return $option;
    });

  } else {
    return Object.keys(src).map(i => $('<option/>').text(i).data('value', src[i]));
  }
  
}

function dd_option_value ($option) {
  const value = $option.data('value');
  return (value === undefined) ? $option.text() : value;
}



//___________________________________________________________________
// Update the options and selected item.
//___________________________________________________________________
function dd_single_reload () {
  
  const $dd     = $(this);
  const sync_id = $dd.closest('.control-row').data('sync_id');
  const req     = $dd.data('req');
  const src     = $dd.data('src');
  let   def     = $dd.data('def');
  
  // Repopulate all the <option> elements.
  //___________________________________________________________________
  $dd.empty().append(new_dd_options(src));
  if (!req) $dd.prepend($('<option/>').data('value', null));
  
  // Determine which value to default to.
  //___________________________________________________________________
  if (def instanceof Function) def = def();
  if (def === undefined)       def = $dd.children(':first').data('value');
  default_value(['SYNC', sync_id], def);
}

function dd_multi_reload () {
  
  const $dd     = $(this);
  const sync_id = $dd.closest('.control-row').data('sync_id');
  const src     = $dd.data('src');
  let   def     = $dd.data('def');
  
  // Repopulate all the <option> elements.
  //___________________________________________________________________
  $dd.empty().append(new_dd_options(src));
  $dd.prepend($('<option disabled/>').data('value', null));
  
  // Determine which value to default to.
  //___________________________________________________________________
  if (def instanceof Function)               def = def();
  if (!def instanceof Array || def === null) def = [def];
  default_value(['SYNC', sync_id], def);
}


//___________________________________________________________________
// Put the value SYNC in this <select>.
//___________________________________________________________________
function dd_single_sync () {
  
  const $dd      = $(this);
  const sync_id  = $dd.closest('.control-row').data('sync_id');
  const selected = get_value(['SYNC', sync_id]);

  const selectedIndex = $dd.children().toArray().reduce((result, option, index) => {
    if (result !== undefined) return result;
    const value = dd_option_value($(option));
    return (value === selected) ? index : undefined;
  }, undefined);
  
  if (selectedIndex === undefined) { // selected doesn't exist in <option>s

    if ($dd.children().length > 0) { // default to first <option>
      const value = dd_option_value($dd.children(':first'));
      set_value(['SYNC', sync_id], value);
      $dd.prop('selectedIndex', 0);

    } else { // <select> doesn't have any <option>s
      set_value(['SYNC', sync_id], undefined);
    }

  } else {
    $dd.prop('selectedIndex', selectedIndex);
  }
  
}

function dd_multi_sync () {
  
  const $dd     = $(this);
  const sync_id = $dd.closest('.control-row').data('sync_id');

  const selected = _.intersection(
    _.uniq(get_value(['SYNC', sync_id]) || []), 
    $dd.children().map((i, el) => { return dd_option_value($(el)); }).toArray() );

  const n = selected.length;
  $dd.prop('selectedIndex', 0);
  $dd.children(':first').text(n ? n + ' selected' : ' ');
  
  set_value(['SYNC', sync_id], n ? selected : null);
}


//___________________________________________________________________
// Update SYNC. Trigger sync.
//___________________________________________________________________
function dd_single_change () {
  
  const $dd     = $(this);
  const sync_id = $dd.closest('.control-row').data('sync_id');
  
  const $option = $dd.children().eq(this.selectedIndex)
  const value   = dd_option_value($option);
  set_value(['SYNC', sync_id], value);

  controls_sync();
  plot_rebuild();
}

function dd_multi_change () {
  
  const $dd     = $(this);
  const sync_id = $dd.closest('.control-row').data('sync_id');
  
  const current  = get_value(['SYNC', sync_id]) || [];
  const $option  = $dd.children().eq(this.selectedIndex);
  const selected = dd_option_value($option);
  set_value(['SYNC', sync_id], _.union(current, [selected]));

  controls_sync();
  plot_rebuild();
}



//___________________________________________________________________
// Add the selected value into the plotting arguments.
//___________________________________________________________________
function dd_collect (e, result) {
  
  const $dd   = $(this);
  const param = $dd.closest('.control-row').data('param');
  
  if ($dd.is(':visible') && param) {
    
    const sync_id = $dd.closest('.control-row').data('sync_id');
    const value   = get_value(['SYNC', sync_id]);

    if (value !== undefined)
      result['plot_args'][param] = value;
    
  }
}





//___________________________________________________________________
// Clear the dropdown selection when the user clicks on 'x'.
//___________________________________________________________________
function $new_dd_x (p) {

  const req = p['req'];

  const $dd_x = $('<i class="dd-x fa-solid fa-xmark" style="visibility:hidden"/>');
  if (!req)
    $dd_x
      .attr('title', 'Remove')
      .on('sync',  dd_x_sync)
      .on('click', dd_x_click);

  return $dd_x;
}

function dd_x_sync () {
  const $dd_x    = $(this);
  const sync_id  = $dd_x.closest('.control-row').data('sync_id');
  const selected = _.defaultTo(get_value(['SYNC', sync_id]), null);
  $dd_x.css('visibility', (selected === null) ? 'hidden' : 'visible');
}

function dd_x_click () {
  const $dd_x     = $(this);
  const sync_id = $dd_x.closest('.control-row').data('sync_id');
  set_value(['SYNC', sync_id], null);
  controls_sync();
  plot_rebuild();
}
