
import { $new_dd_major_row, $new_dd_minor_row }  from '/www/modules/dd.js';
import { $new_selz_div }                         from '/www/modules/selz.js';
import { $new_irs_minor_row }                    from '/www/modules/irs.js';
import { $new_palette_minor_row, aes_plot_args } from '/www/modules/aes.js';


export function md_init () {

  $new_md_control([
    { id: 'x_axis_num',   label: 'x-Axis',   param: 'x',        src: 'cols_num', req: true          },
    { id: 'x_axis_cat',   label: 'x-Axis',   param: 'x',        src: 'cols_cat'                     },
    { id: 'bp_stat_by',   label: 'Stat By',  param: 'stat.by',  src: 'cols_cat', sync_id: 'stat_by' },
    { id: 'rc_stat_by',   label: 'Stat By',  param: 'stat.by',  src: 'cols_cat', sync_id: 'stat_by' },
    { id: 'bdor_stat_by', label: 'Stat By',  param: 'stat.by',  src: 'cols_cat', sync_id: 'stat_by' },
    { id: 'facet_by',     label: 'Facet By', param: 'facet.by', src: 'cols_cat', multi: true        },
    { id: 'hm_colors',    label: 'Color By', param: false,                       multi: true        },
    { id: 'limit_by',     label: 'Limit By', param: false,                       multi: true        },
    { id: 'label_by',     label: 'Label By', param: 'label.by'                                      },
    { id: 'order_by',     label: 'Order By', param: 'order.by'                                      }
  ]);


  //___________________________________________________________________
  // "Stat By" controls.
  //___________________________________________________________________

  $('#bp_stat_by') // Box Plots
    .closest('.control')
    .data('aes_list', ['colors_bool', 'shapes_bool', 'patterns_bool'])
    .append($new_dd_minor_row({ id: 'bp_test', param: 'test', label: 'significance test', src: ['auto', 'none'] }))
    .append($new_md_aes_checkbox_row({ aes_list: ['colors', 'shapes', 'patterns'] }))
    .append($new_palette_minor_row({ sync_id: md_palette_sync_id }))
    .on('sync', md_control_sync);

  $('#rc_stat_by') // Regression / Correlation
    .closest('.control')
    .data('aes_list', ['colors_bool', 'shapes_bool'])
    .append($new_dd_minor_row({ id: 'rc_test', param: 'test', label: 'significance test', src: ['emmeans', 'emtrends', 'none'] }))
    .append($new_md_aes_checkbox_row({ aes_list: ['colors', 'shapes'] }))
    .append($new_palette_minor_row({ sync_id: md_palette_sync_id }))
    .on('sync', md_control_sync);

  $('#bdor_stat_by') // Ordination
    .closest('.control')
    .data('aes_list', ['colors_bool', 'shapes_bool'])
    .append($new_dd_minor_row({ id: 'bdor_test', param: 'test', label: 'significance test', src: ['adonis2', 'mrpp', 'none'] }))
    .append($new_md_aes_checkbox_row({ aes_list: ['colors', 'shapes'] }))
    .append($new_palette_minor_row({ sync_id: md_palette_sync_id }))
    .on('sync', md_control_sync);


  //___________________________________________________________________
  // Heatmap metadata fields to color by using top margin tracks.
  //___________________________________________________________________

  $new_md_control({
    id      : "hm_tracks", 
    param   : false,
    label   : "Metadata Tracks", 
    multi   : true,
    palette : true })
  .data('aes_list', ['colors'])
  .on('collect', function (e, result) {
    
    if ($(this).is(':visible')) {
      
      const col_names = get_value(['SYNC', 'hm_tracks']);

      if (col_names instanceof Array && col_names.length > 0) {
        
        result['plot_args']['tracks'] = {};
        col_names.forEach(function (col_name) {

          const biom_key  = ['col_options', col_name];
          const plot_args = aes_plot_args('colors', biom_key);

          if (typeof plot_args === 'string') {
            result['plot_args']['tracks'][col_name] = plot_args;
          } else {
            result['plot_args']['tracks'][col_name] = { colors: plot_args };
          }
          
        })
      }
      
    }
  });
}




//___________________________________________________________________
// Wrapper around metadata column selector and subset controls.
//___________________________________________________________________
export function $new_md_control (p) {

  if (p instanceof Array) return p.map($new_md_control);
  
  _.defaults(p, { src: 'cols', req: false, multi: false, palette: false, theme: 'gold' });
  _.defaults(p, { sync_id: p['id'], param: guess_param(p) });

  return $new_control()
    .append($new_dd_major_row(p))
    .append(
      $new_control_row({ sync_id: p['sync_id'], class: 'md-subsets' })
        .data('multi',   p['multi'])
        .data('palette', p['palette'])
        .off('sync').on('sync', md_subsets_sync)
    );
}



//___________________________________________________________________
// Handle synchronizing with SYNC.
//___________________________________________________________________
function md_subsets_sync () {
  
  const $md_subsets = $(this);
  const sync_id   = $md_subsets.data('sync_id');
  const multi       = $md_subsets.data('multi');
  const palette     = $md_subsets.data('palette');
  
  const need_cols  = _.castArray(get_value(['SYNC', sync_id]) || []);
  const $have_subs = $md_subsets.children();
  
  // Remove unneeded subs
  $have_subs.filter((i, el) => !need_cols.includes($(el).data('col_name'))).rm();
  
  // Create new subs
  const have_cols = $.makeArray($have_subs.map((i, el) => $(el).data('col_name')));
  const new_cols  = need_cols.filter(col_name => !have_cols.includes(col_name));
  new_cols.forEach(col_name => $new_md_subset(col_name, multi, palette).appendTo($md_subsets));
  
  $md_subsets.children().sync();
}


function $new_md_subset (col_name, multi, palette) {
  
  const col_type = get_value(['BIOM', 'col_types', col_name]);
  
  const $md_subset = $new_div({ class: 'md-subset' })
    .data('col_name', col_name);

  if (multi) {
    $md_subset
      .append($('<div class="md-sub-label"/>').text(col_name))
      .append($new_md_x());
  }

  if (col_type === "cat") {

    // A selectize for picking categorical metadata column values.
    $new_div()
      .append($new_selz_div({   biom_key: ['col_options', col_name], col_name: col_name }))
      .append($new_md_compare({ sync_key: ['col_options', col_name, 'compare'] }))
      .appendTo($md_subset);

  } else {

    // An ionRangeSlider for limiting the numeric range of col_name.
    $new_irs_minor_row({ col_name: col_name, label: false })
      .appendTo($md_subset);
  }

  if (palette) {
    $new_palette_minor_row({ 
        pal_type: col_type, 
        sync_id: ['col_options', col_name, 'palettes', 'colors'] })
      .appendTo($md_subset);
  }
  
  return $md_subset;
}


//___________________________________________________________________
// An 'x' for de-selecting column names.
//___________________________________________________________________
function $new_md_x () {
  return $('<i class="md-x fa-solid fa-xmark" title="Remove"/>').on('click', md_x_click);
}

function md_x_click () {
  
  const $md_x    = $(this);
  const col_name = $md_x.closest('.md-subset').data('col_name');
  const sync_id  = $md_x.closest('.control-row').data('sync_id');
  
  const current  = get_value(['SYNC', sync_id]) || [];
  const selected = _.difference(current, [col_name]);
  set_value(['SYNC', sync_id], selected);
  
  controls_sync();
  plot_rebuild();
}



//___________________________________________________________________
// For bdiv_boxplot, show comparisons dropdown menu.
//___________________________________________________________________
function $new_md_compare (p) {
  
  return $('<div class="control-row minor-row md-compare"/>')
    .data(_.pick(p, ['sync_key']))
    .append(
      $('<em class="tooltip"/>')
      .text("compare: ")
      .attr('title', TOOLTIPS['Compare']) )
    .append($('<select class="dd"/>')
      .append(['all combinations', 'within groups', 'between groups'].map(o => $('<option/>').text(o)))
      .on('change', md_compare_select_change) )
    .on('sync',    md_compare_sync)
    .on('collect', md_compare_collect);
}

function md_compare_sync () {
  
  const $md_compare = $(this);
  const sync_key    = $md_compare.data('sync_key');
  const $select     = $md_compare.children('select');

  const page = get_value(['CONF', 'nav_page']);
  const cmp  = get_value(['SYNC', sync_key], 'all combinations');

  $md_compare.toggleClass('d-none', page !== 'bdbp');
  $select.val(cmp);
}

function md_compare_collect (e, result) {

  const $md_compare = $(this);
  
  if ($md_compare.is(':visible')) {
    
    const col_name = $md_compare.closest('.md-subset').data('col_name');
    const sync_key = $md_compare.data('sync_key');
    const cmp      = get_value(['SYNC', sync_key]);

    if (cmp === "within groups") {
      result['plot_args']['within'] ||= [];
      result['plot_args']['within'].push(col_name);
    }
    if (cmp === "between groups") {
      result['plot_args']['between'] ||= [];
      result['plot_args']['between'].push(col_name);
    }

  }
}

function md_compare_select_change () {
  
  const $select  = $(this);
  const sync_key = $select.closest('.md-compare').data('sync_key');
  
  set_value(['SYNC', sync_key], this.value);
  
  controls_sync();
  plot_rebuild();
}



  function md_palette_sync_id () {
    const col_name = get_value(['SYNC', 'stat_by']);
    return ['col_options', col_name, 'palettes', 'colors'];
  }


  function md_control_sync () {
    const $control    = $(this);
    const active      = $control.hasClass('active');
    const colors_bool = get_value(['SYNC', 'colors_bool']);
    $control.children(':not(.major-row)').toggleClass('d-none', !active);
    $control.children('.dd-palette').toggleClass('d-none', !active || !colors_bool);
  }




  //___________________________________________________________________
  // A page-specific row of checkboxes.
  //___________________________________________________________________
  function $new_md_aes_checkbox_row (p) {
    return $('<div class="checkbox-row" style="border-top: solid 1px #1d3d7c"/>')
      .append(p['aes_list'].map(aes => $new_md_aes_checkbox(aes)))
      .on('sync',    sync_children)
      .on('collect', collect_children);
  }



  //___________________________________________________________________
  // Checkboxes that control visiblity of aes pickers.
  //___________________________________________________________________
  function $new_md_aes_checkbox (aes) {

    const $label = $('<label>' + _.upperFirst(aes) + '</label>')
      .on('sync',    sync_children)
      .on('collect', collect_children);

    const $input = $('<input type="checkbox">')
      .data('aes', aes)
      .on('sync',    md_aes_checkbox_sync)
      .on('collect', md_aes_checkbox_collect)
      .on('change',  md_aes_checkbox_change)
      .prependTo($label);

    return $label;
  }

  function md_aes_checkbox_sync () {
    const $input = $(this);
    const sync_id = $input.data('aes') + "_bool";
    $input.prop('checked', get_value(['SYNC', sync_id]));
  }

  function md_aes_checkbox_change () {

    const $input    = $(this);
    const sync_id = $input.data('aes') + "_bool";
    const checked   = get_value(['SYNC', sync_id]);

    if (checked !== this.checked) {
      set_value(['SYNC', sync_id], this.checked);
      controls_sync();
      plot_rebuild();
    }
  }


  //___________________________________________________________________
  // Compile the `colors`, `shapes`, and `patterns` arguments.
  //___________________________________________________________________
  function md_aes_checkbox_collect (e, result) {

    const $input  = $(this);
      
    if ($input.is(':visible')) {

      const aes     = $input.data('aes');
      const sync_id = aes + "_bool";
      const checked = (get_value(['SYNC', sync_id]) === true);

      if (checked) {
        
        const col_name = get_value(['SYNC', 'stat_by']);
        const biom_key = ['col_options', col_name];
        
        result['plot_args'][aes] = aes_plot_args(aes, biom_key);

      } else {
        result['plot_args'][aes] = false;
      }

    }
    
  }

  