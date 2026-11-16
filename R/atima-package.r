# Imports for the whole package. Roxygen writes NAMESPACE from these tags.
# h5lite is imported for rbiom, which reads and writes atima's stored files
# (HDF5) with it but only suggests it; atima itself only reads and writes
# the attribute that holds a project's group colours (`R/colors.R`).
#' @noRd
#' @importFrom DBI dbConnect dbDisconnect dbExecute dbGetQuery dbListTables
#' @importFrom grDevices col2rgb colors
#' @importFrom h5lite h5_attr_names h5_exists h5_read h5_write
#' @importFrom httpuv runServer staticPath staticPathOptions
#' @importFrom jsonlite base64_dec base64_enc fromJSON toJSON unbox
#' @importFrom methods formalArgs is
#' @importFrom openssl rand_bytes rand_num sha256
#' @importFrom pandoc pandoc_convert
#' @importFrom parallelly availableCores
#' @importFrom rbiom adiv_matrix as_rbiom bdiv_distmat biom_inflate fn_check
#'   fn_check_data fn_schema ggsave list_palettes rarefy sample_sums
#'   taxa_matrix taxa_means write_biom write_tree write_xlsx
#'   %>% %<>%
#' @importFrom rbiom convert_to_phyloseq write_mothur write_qiime2
#' @importFrom rlang %||% exprs_auto_name
#'   is_scalar_character is_scalar_integer is_scalar_integerish is_string
#' @importFrom RSQLite SQLite
#' @importFrom stats median
#' @importFrom tools R_user_dir
#' @importFrom utils adist browseURL hasName head
#'   object.size packageVersion tail write.csv
#' @importFrom webutils parse_http parse_query
NULL
