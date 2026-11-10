

// A checkbox like this:
// <label for="boxplot_flip"><input type="checkbox" id="boxplot_flip">Flip</label>

function $new_checkbox (p) {

  const id        = p['id'];
  const sync_id   = p['sync_id'] || id;
  const param     = p['param'];
  const label_txt = p['label'] || _.upperFirst(param);
  const tooltip   = p['tt'] || TOOLTIPS[sync_id] || TOOLTIPS[param] || TOOLTIPS[label_txt];
  const def       = (p['def'] === true);

  const $checkbox = $('<input type="checkbox">')
    .attr('id', id)
    .on('change',  function () {
      set_value(['SYNC', sync_id], $(this).prop('checked'));
      controls_sync();
      plot_rebuild();
    });

  const $label = $('<label/>')
    .attr('for', id)
    .text(label_txt)
    .prepend($checkbox)
    .on('reload',  function () { default_value(['SYNC', sync_id], def); })
    .on('sync',    function () { $checkbox.prop('checked', get_value(['SYNC', sync_id])); })
    .on('collect', function (e, result) { 
      if ($checkbox.is(':visible') && param) 
        result['plot_args'][param] = get_value(['SYNC', sync_id]); });

  if (tooltip)
    $label.addClass('tooltip').attr('title', tooltip);
  
  return $label;
}


export function $new_checkbox_row (arr) {
  return $new_control_row({ class: 'checkbox-row minor-row', label: false })
    .append(arr.map($new_checkbox));
}


