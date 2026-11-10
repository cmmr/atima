
//___________________________________________________________________
// Defer loading until the 'sharing' page is first viewed.
//___________________________________________________________________
$('#page_sharing').on('shown', function () {
  
  $('#page_sharing').off('shown');

  
  sharing_init_inputs();
  sharing_init_simditor();
  sharing_init_datatable();
  sharing_init_selectize();


  //___________________________________________________________________
  // Synchronize to newly loaded projects.
  //___________________________________________________________________
  $('#page_sharing')

    .addClass('reloadable')
    .on('reload', function () {

      const is_public   = get_value(['BIOM', 'is_public']);
      const title       = get_value(['BIOM', 'unsaved_title'])       || get_value(['BIOM', 'title']);
      const description = get_value(['BIOM', 'unsaved_description']) || get_value(['BIOM', 'description']);
      const access_key  = get_value(['BIOM', 'unsaved_access_key'])  || get_value(['BIOM', 'access_key']);

      $('#sharing_title').val(title);
      $('#sharing_url_base').text(build_url(''));
      $('#sharing_access_key').val(access_key);
      $('#sharing_description').data('simditor').setValue(description);
      $('#sharing_public').toggle(is_public);
      $('#sharing_with').DataTable().ajax.reload();
    })
    
    .reload();



  //___________________________________________________________________
  // Initialize title and access key text inputs.
  //___________________________________________________________________
  function sharing_init_inputs () {

      $('#sharing_title').on('change input', function () {
        let   new_title = $('#sharing_title').val().trim();
        const old_title = get_value(['BIOM', 'title']);
        if (new_title === old_title) new_title = false;
        set_value(['BIOM', 'unsaved_title'], new_title);
        $('#save_btn,#save_as_btn').reload();
      });

      $('#sharing_access_key').on('change input', function () {
        let   new_access_key = $('#sharing_access_key').val().trim();
        const old_access_key = get_value(['BIOM', 'access_key']);
        if (new_access_key === old_access_key) new_access_key = false;
        set_value(['BIOM', 'unsaved_access_key'], new_access_key);
        $('#save_btn,#save_as_btn').reload();
      });
  }



  //___________________________________________________________________
  // Initialize wysiwyg editor.
  //___________________________________________________________________
  function sharing_init_simditor () {
      
    Simditor.locale = 'en-US';
    const simd = new Simditor({
      textarea: $('#sharing_description'),
      toolbar: [
        'title', 'bold', 'italic', 'underline', 'fontScale', '|',
        'ol', 'ul', 'link', 'hr' ] });
    
    const $simwrap = $(simd.wrapper);
    $simwrap.closest('.simditor').css('border', "none");
    $simwrap.find('.toolbar-item').css('width', "30px");
    $simwrap.children('.simditor-body').css({
      'background' : "whitesmoke",
      'border'     : "1px inset #ccc" });

    
    simd.on('valuechanged', function () {

      let   new_description = simd.getValue();
      const old_description = get_value(['BIOM', 'description']);
      
      if (new_description === old_description) new_description = false;
      set_value(['BIOM', 'unsaved_description'], new_description);
      $('#save_btn,#save_as_btn').reload();
    });

  }



  //___________________________________________________________________
  // Initialize sharing_with table.
  //___________________________________________________________________
  function sharing_init_datatable () {
      
    $('#sharing_with').DataTable({
      
      dom: "rt",
      paging: false,
      ordering: false,
      
      columns: [
        { title: 'Name',        data: 1 },
        { title: 'Affiliation', data: 2 },
        { title: 'Permissions', data: 3 } ],
        
      columnDefs: [{ className: 'dt-center', targets: [2] }],
        
      ajax: _.debounce(function (data, callback, settings) {
        api({
          'method'    : "sharing_with",
          'onSuccess' : function (resp) {
            callback({ data: resp['dt_data'] }); }
        });
      }, 500),
      
      createdRow: function (row, data, dataIndex, cells) {
        // data = [user_id, full_name, affiliation, is_editor]
        
        // Attach user_id in <TR>'s data().
        $(row).data('user_id',   data[0]);
        $(row).data('full_name', data[1]);
        
        // Permissions dropdown.
        const disabled = !(get_value(['BIOM', 'is_editor']) || get_value(['CONF', 'is_admin']));
        $(cells[2]).html(
          '<select style="padding:0 10px"' + (disabled ? ' disabled' : '') + '>' +
            '<option>None</option>' + 
            '<option' + ((data[3] === "FALSE") ? ' selected' : '') + '>View</option>' + 
            '<option' + ((data[3] === "TRUE")  ? ' selected' : '') + '>Edit</option>' + 
          '</select>' );
      }
    });
    
    
    
    // Update permissions: none <=> view <=> edit.
    //---------------------------------------------
    $('#sharing_with').on('change', 'select', function() {
      
      const user_id     = $(this).closest('tr').data('user_id');
      const full_name   = $(this).closest('tr').data('full_name');
      const permissions = $(this).val().toLowerCase();
      
      if (permissions === "none") {
        
        swal({
          title: "Revoke Access",
          text: "Are you sure you want to revoke " + full_name + "'s access to this project?",
          buttons: true,
          dangerMode: true
        })
        .then((confirmed) => {
          if (confirmed) {
            api({
              'method'      : "update_permissions",
              'payload'     : { 'user_id': user_id, 'permissions': permissions },
              'spinner_msg' : "Revoking Permissions...",
              'onFinally'   : function () {
                // Reload the table to remove the user.
                $('#sharing_with').DataTable().ajax.reload(null, false);
              }
            });
          } else {
            // Reload the table to undo the canceled change.
            $('#sharing_with').DataTable().ajax.reload(null, false);
          }
        });
        
      } else {
        api({
          'method'      : "update_permissions",
          'payload'     : { 'user_id': user_id, 'permissions': permissions },
          'spinner_msg' : "Updating Permissions...",
          'onFinally'   : function () {
            $('#sharing_with').DataTable().ajax.reload(null, false);
          }
        });
        
      }
      
    
      
    });
  }



  //___________________________________________________________________
  // Initialize selectize for picking users.
  //___________________________________________________________________
  function sharing_init_selectize () {
    
    $("#sharing_add").selectize({
      valueField:  "user_id",
      labelField:  "full_name",
      searchField: ["full_name", "affiliation"],
      options: [],
      create: false,
      render: {
        option: function (item, escape) {
          return (
            "<div>" + 
              "<b>" + escape(item['full_name']) + "</b>, " +
              escape(item['affiliation']) + "<br>" + 
              escape(item['email']) +
            "</div>" ); }},
      load: function (query, callback) {
        if (!query.length) return callback();
        api({
          'method'    : "sharing_user_search",
          'payload'   : { query: query },
          'onSuccess' : function (resp) { callback(resp['users']); },
          'onError'   : function ()     { callback();              }
        });
      },
      onChange: function (user_id) {
        api({
          'method'      : "update_permissions",
          'payload'     : { user_id: user_id, permissions: "view" },
          'spinner_msg' : "Granting Permissions",
          'onSuccess'   : function (resp) {
            $('#sharing_add').data('selectize').clear(true);
            $('#sharing_with').DataTable().ajax.reload(null, false);
          }
        });
      }
    });
    
  }


});
