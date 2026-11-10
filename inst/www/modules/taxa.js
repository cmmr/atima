
import { $new_dd_major_row, $new_dd_minor_row } from '/www/modules/dd.js';
import { $new_palette_minor_row }               from '/www/modules/aes.js';
import { $new_irs_minor_row }                   from '/www/modules/irs.js';
import { $new_selz_div }                        from '/www/modules/selz.js';
import { $new_checkbox_row }                    from '/www/modules/checkbox.js';


export function taxa_init () {

  //___________________________________________________________________
  // Controls for selecting rank and taxa.
  //___________________________________________________________________

  $new_control()

    .append($new_dd_major_row({
      id    : 'rank',
      label : 'Rank',
      param : 'rank',
      src   : 'rank_options',
      def   : function () {
        const ranks = get_value(['BIOM', 'rank_options']);
        // Default to 2nd to last rank.
        if (!ranks)                  { return null;     }
        if (ranks.length === 0)      { return null;     }
        if (ranks.length === 1)      { return ranks[0]; }
        if (ranks.length === 2)      { return ranks[1]; }
        return ranks[ranks.length - 2]; }
    }))

    .append($new_dd_minor_row({
      id    : 'taxa',
      label : 'taxa',
      param : false,
      src   : {
        'most abundant'        : 'taxa_most_ab',
        'minimum abundance'    : 'taxa_min_ab',
        'most significant'     : 'taxa_most_sig',
        'minimum significance' : 'taxa_min_sig',
        'custom list'          : 'taxa_custom', }
    }))


    //___________________________________________________________________
    // Ion RangeSlider for 'Minimum Abundance' filter.
    //___________________________________________________________________
    .append($new_irs_minor_row({
      id     : 'taxa_min_ab', 
      label  : 'abundance', 
      param  : 'taxa',  
      prefix : '>= ', 
      format : '%',
      from   : 2, 
      values : [0.001, 0.005, 0.01, 0.02, 0.05, 0.1, 0.15, 0.2, 0.25],
      toggle : function () {
        const val = get_value(['SYNC', 'taxa']);
        return ['taxa_min_ab', 'taxa_most_sig', 'taxa_min_sig'].includes(val); 
      }}))


    //___________________________________________________________________
    // Ion RangeSlider for 'Most Abundant' filter.
    //___________________________________________________________________
    .append($new_irs_minor_row({
      id     : 'taxa_most_ab', 
      label  : 'display', 
      param  : 'taxa', 
      toggle : function () { return (get_value(['SYNC', 'taxa']) === 'taxa_most_ab'); },
      min    : 1, 
      max    : 25,
      from   :  6,  
      prefix : 'Top ' }))


    //___________________________________________________________________
    // Ion RangeSlider for 'Most Significant' filter.
    //___________________________________________________________________
    .append($new_irs_minor_row({
      id     : 'taxa_most_sig', 
      label  : 'significance', 
      param  : 'p.top', 
      toggle : function () { return (get_value(['SYNC', 'taxa']) === 'taxa_most_sig'); },
      min    : 1, 
      max    : 25,
      from   : 10,  
      prefix : 'Top ' }))


    //___________________________________________________________________
    // Ion RangeSlider for 'Minimum Significance' filter.
    //___________________________________________________________________
    .append($new_irs_minor_row({
      id     : 'taxa_min_sig', 
      label  : 'significance', 
      param  : 'p.top', 
      toggle : function () { return (get_value(['SYNC', 'taxa']) === 'taxa_min_sig'); },
      from   : 2,  
      values : [0.0001, 0.0005, 0.001, 0.005, 0.01, 0.02, 0.05, 0.08, 0.1],
      prefix : 'p <= ' }))


    //___________________________________________________________________
    // Selectize.js for 'Custom List' filter (multi-select).
    //___________________________________________________________________
    .append($new_selz_div({
      id       : 'taxa_custom',
      param    : 'taxa',
      req      : true,
      biom_key : function () { return ['taxa_options', get_value(['SYNC', 'rank'])]; },
      nonce    : function () { return get_value(['SYNC', 'rank']); },
      toggle   : function () { return (get_value(['SYNC', 'taxa']) === 'taxa_custom'); } }))


    //___________________________________________________________________
    // Display an 'other' category on stacked bar charts.
    //___________________________________________________________________
    .append(
      $new_dd_minor_row(
          { id: 'sb_other_bool', param: 'other', label: "'Other' category", def: true })
        .on('configure', function () { $(this).toggleClass('d-none', get_value(['CONF', 'nav_page']) !== 'tasb') }) )


    //___________________________________________________________________
    // Unique colors and/or patterns per taxa on stacked bar charts.
    //___________________________________________________________________
    .append(
      $new_checkbox_row([
          { id: 'sb_colors',   sync_id: 'colors_bool',   param: 'colors',   def: true   }, 
          { id: 'sb_patterns', sync_id: 'patterns_bool', param: 'patterns', def: false } ])
        .on('configure', function () { $(this).toggleClass('d-none', get_value(['CONF', 'nav_page']) !== 'tasb'); }))
    .append(
      $new_palette_minor_row({ sync_id: 'sb_palette', param: 'colors' })
        .on('sync', function () {
          const page        = get_value(['CONF', 'nav_page']);
          const colors_bool = get_value(['SYNC', 'colors_bool']);
          $(this).toggleClass('d-none', page !== 'tasb' || !colors_bool); }) )
    
    
    //___________________________________________________________________
    // On ordination page, only show taxa controls for biplot layers.
    //___________________________________________________________________
    .on('sync', function () {
      if (get_value(['CONF', 'nav_page']) === 'bdor')
        $(this).toggleClass('d-none', !get_value(['SYNC', 'bdor_m']) && !get_value(['SYNC', 'bdor_t']) && !get_value(['SYNC', 'bdor_a']));
    })


    //___________________________________________________________________
    // Disable 'significance' options on taxa abundance heatmap page.
    //___________________________________________________________________
    .on('configure', function () {
      
      $('#taxa option').removeAttr('disabled').removeAttr('style');
      
      if (get_value(['CONF', 'nav_page']) == 'tahm') {
        
        if ($('#taxa select').val().indexOf('significan') >= 0) {
          set_value(['SYNC', 'taxa'], 'taxa_most_ab');
        }
        
        $('#taxa option:contains(significan)')
          .attr('disabled', 'disabled')
          .css('font-style', 'italic');
      }
      
    });

}
