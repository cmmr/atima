

import { $new_dd_minor_row }  from '/www/modules/dd.js';
import { $new_irs_minor_row } from '/www/modules/irs.js';
import { $new_checkbox_row }  from '/www/modules/checkbox.js';


export function layers_init () {

  //___________________________________________________________________
  // BOXPLOT LAYERS
  //___________________________________________________________________

  $new_control()

    .append($new_control_row({ id: 'bp_layers', label: 'Plot Design' }, 'major-row'))

    .append($new_checkbox_row([
      { id: 'bp_flip',   param: 'flip' }, 
      { id: 'bp_stripe', param: 'stripe' } ]))
    
    .append($new_layer_dd_row([

      { id: 'bp_layers_box', default: 'b', options: [
        { value: '_', long: 'blank'                       },
        { value: 'b', long: 'bar',      tt: 'Bar Plot'    },
        { value: 'x', long: 'box',      tt: 'Box Plot'    },
        { value: 'v', long: 'violin',   tt: 'Violin Plot' },
        { value: 'c', long: 'crossbar', tt: 'Crossbar'    } ]},

      { id: 'bp_layers_line', default: 'l', options: [
        { value: '_', long: 'blank'                                             },
        { value: 'l', long: 'linerange',  tt: 'Confidence range.'               },
        { value: 'p', long: 'pointrange', tt: 'Confidence range with mean.'     }, 
        { value: 'e', long: 'errorbar',   tt: 'Confidence range with end caps.' } ]},

      { id: 'bp_layers_dot', default: 's', options: [
        { value: '_', long: 'blank'                    },
        { value: 'd', long: 'dot',   tt: 'Dot Plot'    }, 
        { value: 's', long: 'strip', tt: 'Strip Chart' } ]}

    ]))
    
    .append($new_dd_minor_row([

      { id: 'bp_outliers_bool', param: 'outliers', label: 'show outliers', req: true },

      { id: 'bp_ci', param: 'ci', label: 'error bar', req: true, 
        src: {
          '95% Conf. Interval'   : 'ci', 
          'Standard Deviation'   : 'sd', 
          'Standard Error'       : 'se', 
          'Median Absolute Dev.' : 'mad', 
          'Range'                : 'range' } }
    
    ]))

    .append($new_irs_minor_row([
      { id: 'bp_pt_size',  param: 'pt.size',  label: 'point size',    min: 0.1,  max: 4, step: 0.1, from: 1 },
      { id: 'bp_pt_alpha', param: 'pt.alpha', label: 'point opacity', min: 0.1,  max: 1, step: 0.1, from: 0.5 } ]))

    .on('sync', function () {

      const dot  = get_value(['SYNC', 'bp_layers_dot']);
      const box  = get_value(['SYNC', 'bp_layers_box']);
      const line = get_value(['SYNC', 'bp_layers_line']);
      const outl = get_value(['SYNC', 'bp_outliers_bool']);

      const layers = [dot, box, line].join('') ? [dot, box, line] : ['x'];

      let pts = _.intersection(layers, ['d', 's', 'p']).length > 0;
      pts ||= (layers.includes('x') && outl);

      $('#bp_outliers_bool').closest('.control-row').toggleClass('d-none', !layers.includes('x') || dot !== '');
      $('#bp_pt_size,#bp_pt_alpha').closest('.control-row').toggleClass('d-none', !pts);
      $('#bp_ci').closest('.control-row').toggleClass('d-none', line === '');
      
    });





  //___________________________________________________________________
  // CORRPLOT LAYERS
  //___________________________________________________________________

  $new_control()

    .append($new_control_row({ id: 'rc_layers', label: 'Plot Design' }, 'major-row'))
    
    .append($new_layer_dd_row([

      { id: 'rc_layers_fit', default: 'tc', options: [
        { value: '_',  long: 'blank',      tt: 'Hide Trendline / C.I.'             },
        { value: 't',  long: 'trend',      tt: 'Trendline Only'                    },
        { value: 'c',  long: 'confidence', tt: 'Confidence Interval Only'          },
        { value: 'tc', long: 'trend_ci',   tt: 'Trendline and Confidence Interval' } ]},

      { id: 'rc_layers_pt', default: '_', options: [
        { value: '_',  long: 'blank', tt: 'Hide Scatterplot'            },
        { value: 'p',  long: 'point', tt: 'Scatterplot of All Samples'  },
        { value: 'n',  long: 'name',  tt: 'Scatterplot with Sample IDs' } ]}

    ]))

    .append($new_dd_minor_row([
      { id: 'rc_fit',   param: 'fit', label: 'fit', src: { 'Linear': 'lm', 'Logarithmic': 'log', 'General Additive': 'gam' }, def: 'lm'  },
      { id: 'rare_fit', param: 'fit', label: 'fit', src: { 'Linear': 'lm', 'Logarithmic': 'log', 'General Additive': 'gam' }, def: 'log' } ]))

    .append($new_irs_minor_row([
      { id: 'rc_level',    param: 'level',    label: 'confidence',    min: 0.85, max: 0.99, step: 0.005, from: 0.95, format: '%' },
      { id: 'rc_pt_size',  param: 'pt.size',  label: 'point size',    min: 0.1,  max: 4,    step: 0.1,   from: 1 },
      { id: 'rc_pt_alpha', param: 'pt.alpha', label: 'point opacity', min: 0.1,  max: 1,    step: 0.1,   from: 0.5 } ]))

    .on('sync', function () {
      const page = get_value(['CONF', 'nav_page']);
      $('#rc_level').closest('.control-row').toggleClass('d-none', !['c', 'tc'].includes(get_value(['SYNC', 'rc_layers_fit'])));
      $('#rc_pt_size,#rc_pt_alpha').closest('.control-row').toggleClass('d-none', !['p', 'n'].includes(get_value(['SYNC', 'rc_layers_pt'])));
      $('#rc_fit').closest('.control-row').toggleClass('d-none', page === 'rare');
      $('#rare_fit').closest('.control-row').toggleClass('d-none', page !== 'rare');
    });





  //___________________________________________________________________
  // ORDINATION LAYERS
  //___________________________________________________________________

  $new_control()

    .append($new_control_row({ id: 'bdor_layers', label: 'Plot Design' }, 'major-row'))

    .append($new_control_label('Sample Ordination'))
    .append($new_layer_toggle_row([
        { id: 'bdor_p', value: 'p', long: 'point',   default: true,  tt: 'Point' },
        { id: 'bdor_s', value: 's', long: 'spider',  default: false, tt: 'Spider' },
        { id: 'bdor_e', value: 'e', long: 'ellipse', default: false, tt: 'Ellipse' },
        { id: 'bdor_n', value: 'n', long: 'name',    default: false, tt: 'Name' }
      ]))

    .append($new_control_label('Taxa Biplot'))
    .append($new_layer_toggle_row([
      { id: 'bdor_m', value: 'm', long: 'mean',    default: false, tt: 'Mean' },
      { id: 'bdor_t', value: 't', long: 'taxon',   default: false, tt: 'Taxon' },
      { id: 'bdor_a', value: 'a', long: 'arrow',   default: false, tt: 'Arrow' }
    ]))

    .append($new_irs_minor_row([
      { id: 'ord_pt_size',  param: 'pt.size',  label: 'point size',    min: 0.1, max: 4, step: 0.1, from: 1   }, 
      { id: 'ord_pt_alpha', param: 'pt.alpha', label: 'point opacity', min: 0.1, max: 1, step: 0.1, from: 0.5 }
    ]))

    .on('sync', function () {
      $('#ord_pt_size,#ord_pt_alpha').closest('.control-row').toggleClass('d-none', !get_value(['SYNC', 'bdor_p']));
    });









  //___________________________________________________________________
  // Allows selecting one thumbnails from a dropdown menu.
  //___________________________________________________________________
  function $new_layer_dd (p) {

    const id      = p['id'];
    const def     = p['default'];
    const options = p['options'];

    const $layer_dd = $('<div class="layer-dd"/>');
    const $select = $('<select>').attr('id', id).appendTo($layer_dd);

    $select.selectize({
      items: [def],
      options: options,
      hideSelected: true,
      render: { item: new_layer_img, option: new_layer_img },
      onInitialize: function () {
        this.refreshOptions(false);
        this.$control_input.attr('readonly', true); },
      onChange: function (value) {
        set_value(['SYNC', id], value);
        controls_sync();
        plot_rebuild();
      },
      onDelete: function (value) { return false }
    });

    $select.siblings().find('.layer-img').on('click', function (e) { $select.data('selectize').open(); });

    $layer_dd
      .on('reload',  function () { default_value(['SYNC', id], def); })
      .on('sync',    function () { $select.data('selectize').setValue([get_value(['SYNC', id])], true); })
      .on('collect', function (e, result) { 
        const value = get_value(['SYNC', id]);
        if (value !== '_') {
          result['plot_args']['layers'] ||= '';
          result['plot_args']['layers'] += value; }});
    
    return $layer_dd;
  }

  function $new_layer_dd_row (arr) {
    return $new_div({ class: 'layer-dd-row' })
      .append(arr.map($new_layer_dd));
  }



  //___________________________________________________________________
  // Layer thumbnail images, returned as a string (not a jquery obj).
  //___________________________________________________________________
  function new_layer_img (data, escape) {
    const src   = ' src="/www/img/layers/' + escape(data['long']) + '.png"';
    const title = data['tt'] ? ' title="' + escape(data['tt']) + '"' : '';
    return '<img class="layer-img"' + src + title + '>';
  }




  //___________________________________________________________________
  // All thumbnails are selectable in any combination.
  //___________________________________________________________________
  function $new_layer_toggle_row (arr) {

    return $new_div({ class: 'layer-toggle-row' })
      .append($new_layer_toggle(arr));
  }


  function $new_layer_toggle (p) {

    if (p instanceof Array) return p.map($new_layer_toggle);

    const id    = p['id'];
    const value = p['value'];
    const def   = (p['default'] === true);

    return $('<div class="layer-toggle">')
      .append($(new_layer_img(p, _.identity)))
      .on('reload',  function () { default_value(['SYNC', id], def); } )
      .on('sync',    function () { $(this).toggleClass('active', get_value(['SYNC', id])); })
      .on('click',   function () {
        toggle_value(['SYNC', id]);
        controls_sync();
        plot_rebuild(); })
      .on('collect', function (e, result) { 
        if (get_value(['SYNC', id])) {
          result['plot_args']['layers'] ||= '';
          result['plot_args']['layers'] += value; }});
  }


}
