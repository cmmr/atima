
//___________________________________________________________________
// A row within a control for an ionRangeSlider.
//___________________________________________________________________
export function $new_irs_minor_row (p) {

  if (p instanceof Array) return p.map($new_irs_minor_row);

  const col_name = p['col_name'];

  if (col_name) {    // Subsetting a numeric metadata field.

    _.defaults(p, { 
      type : 'double', 
      min  : get_value(['BIOM', 'col_options', col_name, 'min']), 
      max  : get_value(['BIOM', 'col_options', col_name, 'max']) });

    default_value(['SYNC', 'col_subsets', col_name], { from: p['min'], to: p['max'] });

  } else {           // General purpose numeric slider.

    _.defaults(p, {
      type      : 'single', 
      sync_id : p['id'], 
      param     : guess_param(p) });
  }

  return $new_control_row(p, 'minor-row irs-row')
    .append($new_irs_div(p));
}


function $new_irs_div (p) {

  const $irs_input = $('<input>').attr('id', _.uniqueId('irs_uid_'));
  const $irs_div   = $('<div class="irs-div"/>').append($irs_input);

  $irs_input.ionRangeSlider({
    min      : p['min'],
    max      : p['max'],
    from     : p['from'],
    to       : p['to'],
    step     : p['step'],
    values   : p['values'],
    type     : p['type'],
    prefix   : p['prefix'],
    skin     : 'atima',
    prettify : (p['format'] === '%') ? irs_format_pct : undefined,
    onFinish : irs_finish
  });

  $irs_div
    .data(_.pick(p, ['toggle', 'values', 'from']))
    .data('irs', $irs_input.data('ionRangeSlider'))
    .on('reload',  irs_div_reload)
    .on('sync',    irs_div_sync)
    .on('collect', irs_div_collect)
    .on('rm',      irs_div_rm);

  return $irs_div.reload().sync();
}


function irs_finish (data) {

  const $control_row = $(data.input).closest('.control-row');
  const col_name     = $control_row.data('col_name');
  const sync_id      = $control_row.data('sync_id');

  if (col_name) { set_value(['SYNC', 'col_subsets', col_name],  _.pick(data, ['from', 'to'])); }
  else          { set_value(['SYNC', sync_id], data['from']); }

  controls_sync();
  plot_rebuild();
}


function irs_div_reload () {

  const $irs_div     = $(this);
  const $control_row = $irs_div.closest('.control-row');
  const col_name     = $control_row.data('col_name');

  if (!col_name) {
    const sync_id = $control_row.data('sync_id');
    const from      = $irs_div.data('from');
    default_value(['SYNC', sync_id], from);
  }

}


function irs_div_sync () {

  const $irs_div     = $(this);
  const irs          = $irs_div.data('irs');
  const toggle       = $irs_div.data('toggle');
  const $control_row = $irs_div.closest('.control-row');
  const col_name     = $control_row.data('col_name');
  const sync_id      = $control_row.data('sync_id');
  
  if (toggle) $control_row.toggleClass('d-none', !toggle());

  if (col_name) { irs.update(get_value(['SYNC', 'col_subsets', col_name]));  }
  else          { irs.update({ from: get_value(['SYNC', sync_id]) }); }

}


function irs_div_collect (e, result) {

  const $irs_div     = $(this);
  const $control_row = $irs_div.closest('.control-row');
  const col_name     = $control_row.data('col_name');
  const sync_id      = $control_row.data('sync_id');

  if ($irs_div.is(":visible")) {

    if (col_name) {

      const from  = get_value(['SYNC', 'col_subsets', col_name, 'from']);
      const to    = get_value(['SYNC', 'col_subsets', col_name, 'to']);
      const min   = get_value(['BIOM', 'col_options', col_name, 'min']);
      const max   = get_value(['BIOM', 'col_options', col_name, 'max']);

      if (from > min || to < max) {
        result['subset_args']['num'] ||= {};
        result['subset_args']['num'][col_name] = [from, to];
      }

    } else {
      const from   = get_value(['SYNC', sync_id]);
      const param  = $control_row.data('param');
      const values = $irs_div.data('values');
      result['plot_args'][param] = values ? values[from] : from;
    }

  }
  
}


function irs_div_rm () {
  const $irs_div = $(this);
  $irs_div.data('irs').destroy();
  $irs_div.empty();
}




//___________________________________________________________________
// Display '0.1' as '10%'.
//___________________________________________________________________
function irs_format_pct (v) {
  return (v * 100) + "%";
}

