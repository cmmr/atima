
//___________________________________________________________________
// Fetch server-side data; start interval timeouts.
//___________________________________________________________________
$( document ).ready(function() {
  
  const url = new URL(window.location.href);

  api({
    method      : "init_session",
    spinner_msg : "Initializing Session...",
    payload     : { 
      access_key: url.pathname.substring(1),
      p:          url.searchParams.get('p'),
      k:          url.searchParams.get('k')
    }
  });
  
  // Heartbeat every 30 minutes. Debounced to avoid backlog while browser tab is hidden.
  setInterval(_.debounce(() => api({ method: "heartbeat" }), 1000), 30 * 60 * 1000);
  
  // Begin gallery slideshow
  gallery_cycle('next', false, true);

});


//___________________________________________________________________
// Propagate resize event.
//___________________________________________________________________
$( window ).resize(_.debounce(function() {
  
  increment_value(['CONF', 'nonce', 'combo']);
  increment_value(['CONF', 'nonce', 'resize']);
  
  $('.resizable').each(function () {
    $(this).triggerHandler('resize'); });
    
}, 250));


//___________________________________________________________________
// Propagate trigger handlers on jquery collections.
//___________________________________________________________________
$.fn.sync      = function ()  { return this.each((i, el) => $(el).triggerHandler('sync'));         };
$.fn.rm        = function ()  { return this.each((i, el) => $(el).triggerHandler('rm')).remove();  };
$.fn.reload    = function ()  { return this.each((i, el) => $(el).triggerHandler('reload'));       };
$.fn.configure = function ()  { return this.each((i, el) => $(el).triggerHandler('configure'));    };
$.fn.collect   = function (x) { return this.each((i, el) => $(el).triggerHandler('collect', [x])); };
$.fn.shown     = function (x) { return this.each((i, el) => $(el).triggerHandler('shown',   [x])); };

function      sync_children (e)    { $(this).children().sync();      };
function        rm_children (e)    { $(this).children().rm();        };
function    reload_children (e)    { $(this).children().reload();    };
function configure_children (e)    { $(this).children().configure(); };
function   collect_children (e, x) { $(this).children().collect(x);  };
function     shown_children (e)    { $(this).children().shown();     };







//___________________________________________________________________
// File I/O between server and client.
//___________________________________________________________________
function upload_component (component, component_file) {
  
  // Uploading files requires a more complex payload object.
  const payload = new FormData();
  payload.append("component",      component);
  payload.append("component_file", component_file);
  
  return api({
  	'method'      : "upload_component",
	  'payload'     : payload,
	  'spinner_msg' : "Importing " + component + "." });
}

function download_component (component) {
  api({
  	'method'      : "export/" + component,
	  'spinner_msg' : "Exporting " + component + ".",
	  'onSuccess'   : function (resp) {
	    trigger_download(resp['download_url']); } });
}

function trigger_download (url) {
  const link    = document.createElement('a');
  link.href     = url;
  link.download = url.substr(url.lastIndexOf('/') + 1);
  link.click();
}



function build_url (access_key) {
  const atima_url = new URL(window.location.href);
  return atima_url.protocol + '//' + atima_url.host + '/' + access_key;
};


const ListFmt = new Intl.ListFormat('en', { style: 'long', type: 'conjunction' });



//___________________________________________________________________
// Helper for creating a new <div> with triggers from global.js
//___________________________________________________________________
function $new_div (p) {

  const $div = $('<div/>')
    .on('reload',    reload_children)
    .on('configure', configure_children)
    .on('shown',     shown_children)
    .on('sync',      sync_children)
    .on('collect',   collect_children)
    .on('rm',        rm_children);

  if (p) {
    if (p['id'])    $div.attr('id', p['id']);
    if (p['class']) $div.addClass(p['class']);
    if (p['data'])  $div.data(p['data']);
  }
  
  return $div;
}

function $new_control ()  {
  return $new_div({ class: 'control active' }).appendTo($('#controls'));
}

function $new_control_label (label) {
  return $('<div class="control-label">').text(label);
}

function $new_control_row (p, cls) {

  const $control_row = $new_div(_.omit(p, ['sync_id', 'param', 'col_name', 'label']))
    .addClass('control-row ' + (cls || ''));

  if (p && p['sync_id'])  $control_row.attr('data-sync_id',  p['sync_id']);
  if (p && p['param'])    $control_row.attr('data-param',    p['param']);
  if (p && p['col_name']) $control_row.attr('data-col_name', p['col_name']);
  if (p && p['label'] !== false) $control_row.append($new_row_label(p));

  return $control_row;
}

function $new_row_label (p) {

  const label   = p['label'];
  const tooltip = find_tooltip(p);

  const $row_label = $('<em/>').text(label + ': ');
  if (tooltip) $row_label.attr('title', tooltip).addClass('tooltip');

  return $row_label;
}



//___________________________________________________________________
// Functions to update / fetch values in global objects.
// set() resovles path() and key(); get() resovles val().
//___________________________________________________________________

window.SYNC = {}; // User's PER-project UI selections.
window.CONF = {}; // User's NON-project UI selections.
window.BIOM = {}; // Details of the currently loaded rbiom object.

function get_value (pathkey, default_value) {

  const path = resolve_pathkey(pathkey);
  const key  = path.pop();
  const obj  = get_object(path);
  let   val  = obj[key];

  if (val === undefined) {
    obj[key] = default_value;
    val      = default_value;
  }

  if (val instanceof Function) val = val();
  return val;
}

function set_value (pathkey, val) {
  
  const path = resolve_pathkey(pathkey);
  const key  = path.pop();
  const obj  = get_object(path);

  obj[key] = val;
}

function default_value (pathkey, val) {

  const path = resolve_pathkey(pathkey);
  const key  = path.pop();
  const obj  = get_object(path);
  
  if (obj[key] === undefined) obj[key] = val;
}

function toggle_value (pathkey) {
  
  const path = resolve_pathkey(pathkey);
  const key  = path.pop();
  const obj  = get_object(path);

  obj[key] = !obj[key];
}

function increment_value (pathkey) {
  
  const path = resolve_pathkey(pathkey);
  const key  = path.pop();
  const obj  = get_object(path);

  let val = obj[key];
  if (!(typeof val === 'number')) val = 0;

  obj[key] = val + 1;

  return obj[key]
}

function resolve_pathkey (pathkey) {
  
  if (pathkey instanceof Function) pathkey = pathkey();
  if (!(pathkey instanceof Array)) return [pathkey];

  for (let i = 0; i < pathkey.length; i++) {
    if (pathkey[i] instanceof Function) {
      pathkey[i] = resolve_pathkey(pathkey[i]);
    }
  }

  return _.flattenDeep(pathkey);
}

function get_object (path) {

  let obj = window;
  for (let i = 0; i < path.length; i++) {
    if (obj[path[i]] === undefined) obj[path[i]] = {};
    obj = obj[path[i]];
  }
  
  return obj;
}


window.CONF = {

  nav_page : 'home',
  headers  : {},
  gallery  : { images: [ '1.png', '2.png', '3.png' ] },

  colors_bool   : true,
  shapes_bool   : false,
  patterns_bool : false, 

  nonce : {
    resize : 0,  // When a page is shown, it should check if these
    biom   : 0,  // nonce values are different from the last time it
    combo  : 0   // was visible, and if so, trigger its reload().
  },

  control_set_id : undefined,
  control_sets : {
    rare : [ 'rc_layers', 'rare_depth', 'adiv_metric', 'rc_stat_by', 'facet_by', 'limit_by' ],
    adrc : [ 'rc_layers', 'x_axis_num', 'adiv_metric', 'rc_stat_by', 'facet_by', 'limit_by' ],
    tarc : [ 'rc_layers', 'x_axis_num', 'taxa', 'rc_stat_by', 'facet_by', 'limit_by' ],
    adbp : [ 'bp_layers', 'adiv_metric', 'bp_stat_by', 'x_axis_cat', 'facet_by', 'limit_by' ],
    bdbp : [ 'bp_layers', 'bdiv_metric', 'bp_stat_by', 'x_axis_cat', 'facet_by', 'limit_by' ],
    tabp : [ 'bp_layers', 'taxa', 'bp_stat_by', 'x_axis_cat', 'facet_by', 'limit_by' ],
    bdhm : [ 'bdiv_metric', 'hm_grid', 'hm_margins', 'hm_tracks', 'limit_by' ],
    tahm : [ 'taxa', 'hm_grid', 'hm_margins', 'hm_tracks', 'limit_by' ],
    bdor : [ 'bdor_layers', 'taxa', 'bdiv_metric', 'bdor_metric', 'bdor_stat_by', 'shapes', 'facet_by', 'limit_by' ],
    tasb : [ 'taxa', 'taxa_other_bool', 'label_by', 'order_by', 'facet_by', 'limit_by' ]
  },

  palette_options : {

    colors : {

      // Qualitative Colors, for categorical metadata
      cat:  [ 'classic', 'okabe', 'carto', 'r4', 'polychrome', 'tol', 
              'bright', 'light', 'muted', 'vibrant', 'tableau', 
              'alphabet', 'tableau20', 'kelly', 'fishy' ],
      
      // Sequential/Diverging Colors, for numerical metadata
      num:  [ 'acton', 'bamako', 'batlow', 'bilbao', 'buda', 'davos', 
              'devon', 'grayC', 'hawaii', 'imola', 'lajolla', 'lapaz', 
              'nuuk', 'oslo', 'tokyo', 'turku', 'bam', 'berlin', 'broc', 
              'cork', 'lisbon', 'roma', 'tofino', 'vanimo', 'vik' ]
    },

    shapes :   { cat: [ 'shapes' ],   num: [] },
    patterns : { cat: [ 'patterns' ], num: [] }
  },

  aes_options : {
    
    'shapes':     [ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 
                    10, 11, 12, 13, 14, 15, 16, 17, 18 ],
  
    'patterns':   [ 'brick', 'chevron', 'fish', 'grid', 'herringbone', 'hexagon', 
                    'octagon', 'rain', 'saw', 'shingle', 'rshingle', 'stripe', 'wave' ],
    
    // Categorical palettes definitions.
    'custom':     [ '#E69F00', '#56B4E9', '#009E73', '#F0E442', '#0072B2', '#D55E00', 
                    '#CC79A7' ],
    
    'classic':    [ '#1F77B4', '#FF7F0E', '#2CA02C', '#D62728', '#9467BD', '#8C564B', 
                    '#E377C2', '#7F7F7F', '#BCBD22', '#17BECF' ],
        
    'okabe':      [ '#E69F00', '#56B4E9', '#009E73', '#F0E442', '#0072B2', '#D55E00', 
                    '#CC79A7', '#999999' ],
  
    'carto':      [ '#88CCEE', '#CC6677', '#DDCC77', '#117733', '#332288', '#AA4499', 
                    '#44AA99', '#999933', '#882255', '#661100', '#6699CC', '#888888' ],
    
    'r4':         [ '#DF536B', '#61D04F', '#2297E6', '#28E2E5', '#CD0BBC', '#F5C710', 
                    '#9E9E9E', '#000000' ],
    
    'polychrome': [ '#5A5156', '#E4E1E3', '#F6222E', '#FE00FA', '#16FF32', '#3283FE', 
                    '#FEAF16', '#B00068', '#1CFFCE', '#90AD1C', '#2ED9FF', '#DEA0FD', 
                    '#AA0DFE', '#F8A19F', '#325A9B', '#C4451C', '#1C8356', '#85660D', 
                    '#B10DA1', '#FBE426', '#1CBE4F', '#FA0087', '#FC1CBF', '#F7E1A0', 
                    '#C075A6', '#782AB6', '#AAF400', '#BDCDFF', '#822E1C', '#B5EFB5', 
                    '#7ED7D1', '#1C7F93', '#D85FF7', '#683B79', '#66B0FF', '#3B00FB' ],
    
    'tol':        [ '#332288', '#6699CC', '#88CCEE', '#44AA99', '#117733', '#999933', 
                    '#DDCC77', '#661100', '#CC6677', '#AA4466', '#882255', '#AA4499' ],
        
    'bright':     [ '#4477AA', '#EE6677', '#228833', '#CCBB44', '#66CCEE', '#AA3377', 
                    '#BBBBBB' ],
        
    'light':      [ '#77AADD', '#EE8866', '#EEDD88', '#FFAABB', '#99DDFF', '#44BB99', 
                    '#BBCC33', '#AAAA00' ],
        
    'muted':      [ '#CC6677', '#332288', '#DDCC77', '#117733', '#88CCEE', '#882255', 
                    '#44AA99', '#999933', '#AA4499' ],
    
    'vibrant':    [ '#EE7733', '#0077BB', '#33BBEE', '#EE3377', '#CC3311', '#009988', 
                    '#BBBBBB' ],
        
    'tableau':    [ '#4E79A7', '#F28E2B', '#E15759', '#76B7B2', '#59A14F', '#EDC948', 
                    '#B07AA1', '#FF9DA7', '#9C755F', '#BAB0AC' ],
    
    'alphabet':   [ '#AA0DFE', '#3283FE', '#85660D', '#782AB6', '#565656', '#1C8356', 
                    '#16FF32', '#F7E1A0', '#E2E2E2', '#1CBE4F', '#C4451C', '#DEA0FD', 
                    '#FE00FA', '#325A9B', '#FEAF16', '#F8A19F', '#90AD1C', '#F6222E', 
                    '#1CFFCE', '#2ED9FF', '#B10DA1', '#C075A6', '#FC1CBF', '#B00068', 
                    '#FBE426', '#FA0087' ],
    
    'tableau20':  [ '#1F77B4', '#AEC7E8', '#FF7F0E', '#FFBB78', '#2CA02C', '#98DF8A', 
                    '#D62728', '#FF9896', '#9467BD', '#C5B0D5', '#8C564B', '#C49C94', 
                    '#E377C2', '#F7B6D2', '#7F7F7F', '#C7C7C7', '#BCBD22', '#DBDB8D', 
                    '#17BECF', '#9EDAE5' ],
    
    'kelly':      [ '#F3C300', '#875692', '#F38400', '#A1CAF1', '#BE0032', '#C2B280', 
                    '#848482', '#008856', '#E68FAC', '#0067A5', '#F99379', '#604E97', 
                    '#F6A600', '#B3446C', '#DCD300', '#882D17', '#8DB600', '#654522', 
                    '#E25822', '#2B3D26', '#222222' ],
          
    'fishy':      [ '#6388B4', '#FFAE34', '#EF6F6A', '#8CC2CA', '#C3BC3F', '#55AD89', 
                    '#BB7693', '#BAA094', '#767676' ]
  }

};

