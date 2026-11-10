
import { aes_init }    from '/www/modules/aes.js';
import { dd_init }     from '/www/modules/dd.js';
import { layers_init } from '/www/modules/layers.js';
import { md_init }     from '/www/modules/md.js';
import { taxa_init }   from '/www/modules/taxa.js';


export async function controls_init () {

  await Promise.all([
    new Promise((resolve) => { resolve(aes_init());    }),
    new Promise((resolve) => { resolve(dd_init());     }),
    new Promise((resolve) => { resolve(md_init());     }),
    new Promise((resolve) => { resolve(layers_init()); }),
    new Promise((resolve) => { resolve(taxa_init());   })
  ]);

  
  $('#controls')
    .on('reload',    reload_children)
    .on('configure', controls_configure)
    .on('sync',      sync_children)
    
    // Numeric text inputs for plot width, height, and zoom.
    .append(
      $('<div id="sizers" style="display:flex"/>')
        .on('collect', function (e, result) {
          result['save_args']['units'] = 'px';
          $(this).find('input').collect(result['save_args']) })

        .append(
          $('<div/>')
            .append($('<b class="tooltip"/>').text('Zoom').attr('title', TOOLTIPS['Zoom']))
            .append(
              $('<input type="number" id="plot_zoom" min=.1 max=5 step=.1 value=1>')
                .bind('keyup mouseup', plot_rebuild)
                .on('collect', function (e, save_args) { save_args['dpi'] = Math.round(100 * this.value); }) ))
        .append(
          $('<div/>')
            .append($('<b class="tooltip"/>').text('Width').attr('title', TOOLTIPS['Width']))
            .append(
              $('<input type="number" id="plot_width" min=50 max=5000 step=50 value=0>')
                .bind('keyup mouseup', plot_rebuild)
                .on('collect', function (e, save_args) { save_args['width'] = this.value; }) ))
        .append(
          $('<div/>')
            .append($('<b class="tooltip"/>').text('Height').attr('title', TOOLTIPS['Height']))
            .append(
              $('<input type="number" id="plot_height" min=50 max=5000 step=50 value=0>')
                .bind('keyup mouseup', plot_rebuild)
                .on('collect', function (e, save_args) { save_args['height'] = this.value; }) ))
    );

}


//___________________________________________________________________
// Change which controls are shown/hidden.
//___________________________________________________________________
function controls_configure () {

  const control_set_id = get_value(['CONF', 'control_set_id']);
  
  if (control_set_id) {
    
    const control_set = get_value(['CONF', 'control_sets', control_set_id]);
    
    // Re-order the elements to match the above list's order
    $('#controls').children('.control').addClass('d-none');
    control_set.forEach(
      function (id) {
        $('#' + id)
          .closest('.control')
          .appendTo($('#controls'))
          .removeClass('d-none')
          .configure()
          .sync();
    });
    
    $('#controls').append($('#sizers'));
  }

  $(this).children().configure();
}

