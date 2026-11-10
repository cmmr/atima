

//___________________________________________________________________
// Initialize the jsTree project browser.
//___________________________________________________________________
  
// Common settings among the jsTree instances.
$.jstree.defaults.core.force_text = true;
$.jstree.defaults.core.multiple = false;
$.jstree.defaults.core.check_callback = true;
$.jstree.defaults.contextmenu.select_node = false;
$.jstree.defaults.dnd.check_while_dragging = true;
$.jstree.defaults.contextmenu.items = jsTree_contextMenu;
$.jstree.defaults.search.show_only_matches = true;
$.jstree.defaults.search.show_only_matches_children = true;



//___________________________________________________________________
// Fetch the public and private collections for jsTree.
//___________________________________________________________________
function jsTree_rebuild (jstree_data) {

  if ($('#public_collections').hasClass('jstree')) {
    $("#public_collections").jstree("destroy");
  }
  
  if ($('#private_collections').hasClass('jstree')) {
    $("#private_collections").jstree("destroy");
  }
  
  
  $('#public_collections')
    .jstree({
      'plugins' : [ "search" ],
      'core'    : { 'data': jstree_data['public'] } })
    .on("select_node.jstree", jsTree_select)
    .on("hover_node.jstree",  jsTree_hover)
    .on("ready.jstree",       jsTree_highlight_node);
    
  
  $('#private_collections')
    .jstree({
      'plugins' : [ "dnd", "contextmenu", "search" ],
      'core'    : {
        'data': jstree_data['private'],
        'check_callback': function (operation, node, node_parent) {
          if (operation === "move_node") {
            return node_parent['id'].startsWith("C");
          }
          return true;  // allow all other operations
        }
      }
    })
    .on("select_node.jstree", jsTree_select)
    .on("hover_node.jstree",  jsTree_hover)
    .on('rename_node.jstree', jsTree_rename)
    .on("move_node.jstree",   jsTree_move)
    .on("ready.jstree",       jsTree_highlight_node);
  
    
  // Double-check element sizing.
  $('#page_home').triggerHandler('resize');
}



//___________________________________________________________________
// Inserts or updates a given node.
//___________________________________________________________________
function jsTree_insert (jstree_node) {
  const parent  = jstree_node['parent'] || '#';
  const pr_tree = $('#private_collections').jstree();
  pr_tree.delete_node(jstree_node['id']);
  pr_tree.create_node(parent, _.omit(jstree_node, 'parent'), 'first');
}



//___________________________________________________________________
// Highlight the currently loaded project in the jsTree.
//___________________________________________________________________
function jsTree_highlight_node () {
  
  $('#collections>div:jstree').each(function () {
  	$(this).jstree().deselect_all(true);
  });
  
  // Searches all jsTrees
  const target_node = get_value(['BIOM', 'node_id']);
  const target_tree = $.jstree.reference(target_node);
  
  if (target_tree) {

    target_tree.select_node(target_node, true);

    const is_public = get_value(['BIOM', 'is_public']);
    $('#public_tab').toggleClass('active',   is_public);
    $('#private_tab').toggleClass('active', !is_public);
    $('#public_collections').toggle(is_public);
    $('#private_collections').toggle(!is_public);
  }
}



//___________________________________________________________________
// Open a project when selected from the collection list.
//___________________________________________________________________
function jsTree_select (e, obj) {
  
  const new_node_id = obj['node']['id'];
  const old_node_id = get_value(['BIOM', 'node_id']);
  
  if (new_node_id.startsWith('P')) {
    
    if (new_node_id !== old_node_id) {
      api({
  	  	'method'      : "jstree_select",
  		  'payload'     : { 'node_id': new_node_id },
  		  'spinner_msg' : "Opening '" + obj['node']['text'] + "'..."
  	  });
    }
	  
  } else { // Open/close folders on click.
    obj['instance'].deselect_node(obj['node']);
    obj['instance'].toggle_node(obj['node']);
  }
  
}


//___________________________________________________________________
// Preview a project when hovered in the collection list.
//___________________________________________________________________
function jsTree_hover (e, obj) {

  let info = obj['node']['original']['info'];
  console.log(info);
  
  if (info) {
    $('#preview_title').text(info['title']);
    $('#preview_description').html(DOMPurify.sanitize(info['description']));
    $('#preview_n_samples').text(info['n_samples']);
    $('#preview_n_taxa').text(info['n_taxa']);
    $('#preview_median_depth').text(info['median_depth']);
    $('#preview_has_tree').text((info['has_tree'] ? "Yes" : "No"));
    $('#preview_editors').text(ListFmt.format(info['editors']));
    $('#preview_meta_colnames').text(ListFmt.format(info['meta_colnames']));
    
    $('#preview_lastviewed>b').text(
      new Date(Date.parse(info['viewed_utc'] + ' UTC'))
        .toLocaleDateString(undefined, {month: "long", day: "numeric", year: "numeric"}) );
    $('#preview_lastviewed').toggleClass('d-none', info['viewed_utc'] === null);
    
    $('#preview_share_url').text(build_url(info['access_key']));
    $('#preview_dload_url').text($('#preview_share_url').text() + "/rare.json");
    
    $('#introduction').hide();
    $('#preview').show();
  }
}


//___________________________________________________________________
// Show atima intro text again when rows aren't hovered.
//___________________________________________________________________
$('#collections,#preview').on('mouseleave', _.debounce(function () {
  
  if ($('#collections:hover,#preview:hover').length == 0) {
    $('#preview').hide();
    $('#introduction').show();
  }
  
}, 400));


//___________________________________________________________________
// Rename a project via the collection's context menu.
//___________________________________________________________________
function jsTree_rename (e, obj) {
	if (obj.text !== obj.old) {
    api({
	  	'method'  : "jstree_rename",
		  'payload' : {
		    'node_id'     : obj['node']['id'],
		    'jstree_text' : obj['text'] },
	    'onError' : function (jqXHR) {
        $("#private_collections").jstree("set_text", obj['node'], obj.old);
        raise_error("jstree_rename", jqXHR.responseText);
	    },
	    'onSuccess' : function (resp) {
        if (resp['title']) {
          set_value(['BIOM', 'title'], resp['title']);
          $('body>header').triggerHandler('reload');
        }
	    }
	  });
	}
}



//___________________________________________________________________
// React to dragging and dropping a project/collection.
//___________________________________________________________________
function jsTree_move (e, obj) {
  api({
  	'method'  : "jstree_move",
	  'payload' : {
	    'node_id'        : obj['node']['id'],
	    'parent_node_id' : obj['parent'] }
  });
}



//___________________________________________________________________
// Right-click context menu options.
//___________________________________________________________________
function jsTree_contextMenu (node, cb) {
          
  let tree = $(this.element).jstree(true);
  
  return {
    "create": {
      "label": "New Folder",
      "icon": "fa fa-folder-plus",
      "separator_before": false,
      "separator_after": false,
      "action": function (obj) {
        
        api({
    	  	'method'    : "jstree_create",
    		  'payload'   : { 'node_id': node['id'] },
    		  'onSuccess' : function (resp) {
        
            let parent = tree.get_node(resp['parent_id']);
            let node   = tree.create_node(parent, resp['node']);
            tree.edit(node);
    	    }
    	  });
      }
    },
    
    "rename": {
      "label": "Rename",
      "icon": "fa fa-pen",
      "separator_before": false,
      "separator_after": false,
      "_disabled": !node['original']['editor'],
      "action": function (obj) { tree.edit(node); }
    },
    
    "leave": {
      "label": "Leave",
      "icon": "fa fa-circle-minus",
      "separator_before": false,
      "separator_after": false,
      "_disabled": node['id'].startsWith('C'),
      "action": function (obj) {
        
        api({
    	  	'method'    : "jstree_leave",
    	  	'confirm'   : "The project will remain in atima for other users," + 
    	  	              " but you will no longer have access to it.",
    		  'payload'   : { 'node_id' : node['id'] },
    		  'onSuccess' : function () { tree.delete_node(node); }
    	  });
        
      }
    },
    
    "delete": {
      "label": "Delete",
      "icon": "fa fa-trash-can",
      "separator_before": false,
      "separator_after": false,
      "_disabled": !tree.is_leaf(node) || !node['original']['editor'],
      "action": function (obj) {
        
        let confirmMsg = null;
        if (node['id'].startsWith('P')) {
          confirmMsg = "The project will be permanently removed from atima." + 
    	  	             " If this project is shared with other users, they"   + 
    	  	             " will lose access to it as well."
        }
        
        api({
    	  	'method'    : "jstree_delete",
    	  	'confirm'   : confirmMsg,
    		  'payload'   : { 'node_id' : node['id'] },
    		  'onSuccess' : function (resp) { tree.delete_node(node); }
    	  });
    	  
      }
    }
  };
}




//___________________________________________________________________
// Limit displayed collections to search results.
//___________________________________________________________________
$('#search_collections')
  .on('keyup input paste', _.debounce(function () {
    
    if ($(this).val()) {
      $('#search_collections_div').children().css('color', "#8b0000");
    } else {
      $('#search_collections_div').children().css('color', "gray");
    }
  
    const query = $('#search_collections').val();
    $('#public_collections').jstree("search", query);
    $('#private_collections').jstree("search", query);

  }, 250))
  .on('blur', function () {
    if (!$(this).val()) {
      $('#search_collections_div').children().css('color', "gray");
    }
  });
