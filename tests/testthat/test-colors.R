# A colour for each group of a field, kept in the project's HDF5 files
# (`R/colors.R`) and given to the figures coloured by that field
# (`project_colors()`, `R/worker-plot.R`).


test_that("colors are hex codes or R's color names, and are stored as hex codes", {

  expect_identical(
    as_hex_color(c("#f00", "#0072b2", "red", "Dark Red", "steel blue", "#11223380")),
    c("#FF0000", "#0072B2", "#FF0000", "#8B0000", "#4682B4", "#11223380") )

  # Palette positions, "transparent", malformed codes, CSS functions.
  expect_true(all(is.na(as_hex_color(c("1", "0", "transparent", "#12345", "#GGGGGG", "rgb(1,2,3)", "", NA)))))

  expect_identical(
    check_group_colors(list(Male = "#0072b2", Female = "tomato")),
    c(Male = "#0072B2", Female = "#FF6347") )
  expect_identical(check_group_colors(c(`Ménière's` = "navy")), c(`Ménière's` = "#000080"))
  expect_length(check_group_colors(list()), 0L)
  expect_length(check_group_colors(NULL), 0L)

  expect_error(check_group_colors(list(Male = "nope")), "'nope' for 'Male', which is neither a hex code")
  expect_error(check_group_colors(list(Male = 3)), "one color, as a string")
  expect_error(check_group_colors(list(Male = list("red"))), "one color, as a string")
  expect_error(check_group_colors(c("red", "blue")), "name the group")
  expect_error(check_group_colors(stats::setNames(c("red", "blue"), c("A", ""))), "no name")
  expect_error(check_group_colors(c(A = "red", A = "blue")), "names the group 'A' twice")
  expect_error(check_group_colors(stats::setNames(rep("red", 1001), paste0("g", 1:1001))), "at most 1000")
})


test_that("colors are kept in an HDF5 file, where other readers do not see them", {

  file   <- withr::local_tempfile(fileext = ".h5")
  colors <- list(Sex = c(Male = "#0000FF", Female = "#FF0000"), `Body Site` = c(`Ménière` = "#00FF00"))

  rbiom::write_biom(rbiom::hmp50, file, format = "hdf5")
  expect_identical(read_colors(file), list())
  expect_true(write_colors(file, colors))
  expect_identical(read_colors(file), colors)

  # rbiom reads the file as before.
  biom <- rbiom::as_rbiom(file)
  expect_identical(biom$n_samples, 50L)
  expect_identical(levels(biom$metadata$Sex), c("Female", "Male"))

  # Written again, the colors are replaced; none, and nothing is written.
  write_colors(file, list(Sex = c(Male = "#000000")))
  expect_identical(read_colors(file), list(Sex = c(Male = "#000000")))
  expect_false(write_colors(file, list()))
  expect_false(write_colors(file, list(Sex = character(0))))

  # JSON has no place for them.
  json <- withr::local_tempfile(fileext = ".json")
  rbiom::write_biom(rbiom::hmp50, json, format = "json")
  expect_false(write_colors(json, colors))
  expect_identical(read_colors(json), list())
  expect_identical(read_colors(withr::local_tempfile()), list())

  # A file from elsewhere: what is not a field's colors is left out.
  h5lite::h5_write(I('{"Sex": {"Male": "red", "Female": "nope"}, "Age": {"30": "#123456"}, "": {"a": "red"}, "X": 5}'), file, name = "/", attr = colors_attr)
  expect_identical(read_colors(file), list(Age = c(`30` = "#123456")))
  h5lite::h5_write(I("not JSON"), file, name = "/", attr = colors_attr)
  expect_identical(read_colors(file), list())
})


test_that("a figure gets the project's colors for the field it is colored by, unless it has its own", {

  biom   <- rbiom::rarefy(rbiom::hmp50)
  colors <- list(
    Sex         = c(Male = "#0000FF", Female = "#FF0000"),
    `Body Site` = c(Stool = "#8B4513", Saliva = "#FF69B4", Gone = "#000000"),
    Age         = c(`30` = "#123456") )

  # In the order of the levels, and only for groups the data has.
  expect_identical(
    project_colors("adiv_boxplot", list(x = "Body Site"), biom, colors)$colors,
    c(Saliva = "#FF69B4", Stool = "#8B4513") )

  # `stat.by` before `x`; TRUE is the default.
  args <- project_colors("adiv_boxplot", list(x = "Body Site", stat.by = "Sex", colors = TRUE), biom, colors)
  expect_identical(args$colors, c(Female = "#FF0000", Male = "#0000FF"))

  # The figure's own choice comes first.
  for (own in list("bright", FALSE, c("red", "blue"), c(Male = "green")))
    expect_identical(project_colors("adiv_boxplot", list(x = "Sex", colors = own), biom, colors)$colors, own)

  # Nothing to add: no groups, a numeric field, no colors, colors by taxa.
  expect_null(project_colors("bdiv_ord_plot", list(), biom, colors)$colors)
  expect_null(project_colors("adiv_corrplot", list(x = "Age", stat.by = "BMI"), biom, colors)$colors)
  expect_null(project_colors("adiv_boxplot", list(x = "Sex"), biom, list())$colors)
  expect_null(project_colors("taxa_stacked", list(rank = "Phylum"), biom, colors)$colors)

  # A field compared in pairs: the field's groups (rbiom colors a group's
  # distances within itself; a pair gets a default).
  expect_identical(project_colors("bdiv_boxplot", list(x = "==Sex"), biom, colors)$colors, colors$Sex[c("Female", "Male")])

  # After the sample filter, only the groups that are left.
  sub <- subset_biom(biom$clone(), list(cat = list(`Body Site` = c("Stool", "Mid vagina"))))
  expect_identical(project_colors("adiv_boxplot", list(x = "Body Site"), sub, colors)$colors, c(Stool = "#8B4513"))

  # Heat map tracks named by their field get them; a track with colors of
  # its own keeps them; a numeric track has none to get.
  expect_identical(
    project_colors("taxa_heatmap", list(tracks = c("Sex", "Age")), biom, colors)$tracks,
    list(Sex = c(Female = "#FF0000", Male = "#0000FF"), "Age") )
  expect_identical(
    project_colors("bdiv_heatmap", list(tracks = list(Sex = list(colors = "bright"), `Body Site` = list(label = "Site"))), biom, colors)$tracks,
    list(Sex = list(colors = "bright"), `Body Site` = list(label = "Site", colors = c(Saliva = "#FF69B4", Stool = "#8B4513"))) )
  expect_identical(project_colors("taxa_heatmap", list(tracks = "Age"), biom, colors)$tracks, "Age")
})


test_that("rbiom draws the project's colors, and its R code has them", {

  biom   <- rbiom::rarefy(rbiom::hmp50)
  colors <- list(Sex = c(Male = "#0000FF", Female = "#FF0000"), `Body Site` = c(Stool = "#8B4513"))
  draw   <- function (fn, args) {
    args <- project_colors(fn, args, biom, colors)
    do.call(base::getExportedValue("rbiom", fn), c(list(biom = biom), args))
  }
  fills <- function (p) unique(ggplot2::ggplot_build(p)$data[[1]]$colour)

  p <- draw("adiv_boxplot", list(x = "Sex", layers = "x"))
  expect_setequal(fills(p), c("#FF0000", "#0000FF"))
  expect_match(attr(p, "cmd"), "colors = c('Female' = \"#FF0000\", 'Male' = \"#0000FF\")", fixed = TRUE)

  # The code, run on the same data, draws the same figure.
  again <- eval(parse(text = attr(p, "cmd")), list(biom = biom), asNamespace("rbiom"))
  expect_equal(ggplot2::ggplot_build(again)$data, ggplot2::ggplot_build(p)$data, ignore_attr = TRUE)

  # Groups without a color get rbiom's defaults; the field's order of
  # levels does not change which group has which color.
  p <- draw("bdiv_ord_plot", list(stat.by = "Body Site"))
  expect_match(attr(p, "cmd"), "colors = c('Stool' = \"#8B4513\")", fixed = TRUE)

  md <- biom$metadata
  md$Sex <- factor(md$Sex, levels = c("Male", "Female"))
  biom$metadata <- md
  p <- draw("adiv_boxplot", list(x = "Sex", layers = "x"))
  expect_match(attr(p, "cmd"), "colors = c('Male' = \"#0000FF\", 'Female' = \"#FF0000\")", fixed = TRUE)
  built <- ggplot2::ggplot_build(p)$data[[1]]
  expect_identical(unique(built$colour[built$x == 1]), "#0000FF")

  p <- draw("taxa_heatmap", list(rank = "Phylum", tracks = c("Sex")))
  expect_match(attr(p, "cmd"), "tracks = list(Sex = c('Male' = \"#0000FF\", 'Female' = \"#FF0000\"))", fixed = TRUE)
})
