library(grid)
library(ggplot2)
library(fillpattern)
library(khroma)
library(magick)
library(magrittr)

dir.create("inst/www/img/aes", showWarnings = FALSE)

# Shapes
local({
  
  for (i in 0:18) {
    
    p <- ggplot() + 
      geom_point(aes(x = 1, y = 1), shape=i) + 
      theme_void()
    
    fp <- sprintf("inst/www/img/aes/%s.png", i)
    ggsave(fp, p, width = 100, height = 100, units = "px", dpi = 1000)
    
    image_read(fp) %>%
      image_trim() %>%
      image_scale("40x40") %>%
      image_extent("40x40") %>%
      image_write(fp, "png")
    
  }
  
})


# Patterns
local({
  
  patterns <- c(
    "brick", "chevron", "fish", "grid", "herringbone", "hexagon", 
    "octagon", "rain", "saw", "shingle", "rshingle", "stripe", "wave" )
  
  for (i in patterns) {
    
    ragg::agg_png(
      filename = sprintf("inst/www/img/aes/%s.png", i),
      width    = 40,
      height   = 40 )
    grid.rect(gp = gpar(fill = fill_pattern(i)), width = 1, height = 1)
    dev.off()
    
  }
  
})


# Diverging and sequential gradients are defined by
# a lot of individual steps. Pull and plot through khroma.
local({
  
  heat <- c( "bam", "berlin", "broc", "cork", "lisbon", "roma", 
                  "tofino", "vanimo", "vik" )
  
  num <-  c( "acton", "bamako", "batlow", "bilbao", "buda", "davos", 
             "devon", "grayC", "hawaii", "imola", "lajolla", "lapaz", 
             "nuuk", "oslo", "tokyo", "turku" )
  
  n_colors <- with(khroma::info(), setNames(max, palette))
  for (i in c('heat', 'num')) {
    for (pal in get(i)) {
      fp <- sprintf("inst/www/img/aes/%s.png", pal)
      png(filename = fp, width = 200, height = 40)
      try(plot(khroma::color(pal)(n_colors[[pal]])), silent = TRUE)
      dev.off()
      image_read(fp) %>% image_trim() %>% image_write(fp)
    }
  }
  
})


# Qualitative (categorical) colors have been pulled from multiple sources.
local({
  
  cat <- list(
    
    "okabe"      = c( "E69F00", "56B4E9", "009E73", "F0E442", "0072B2", "D55E00", 
                      "CC79A7", "999999" ),
                      
    "carto"      = c( "88CCEE", "CC6677", "DDCC77", "117733", "332288", "AA4499", 
                      "44AA99", "999933", "882255", "661100", "6699CC", "888888"),
                      
    "r4"         = c( "DF536B", "61D04F", "2297E6", "28E2E5", "CD0BBC", "F5C710", 
                      "9E9E9E", "000000"),
                      
    "polychrome" = c( "5A5156", "E4E1E3", "F6222E", "FE00FA", "16FF32", "3283FE", 
                      "FEAF16", "B00068", "1CFFCE", "90AD1C", "2ED9FF", "DEA0FD", 
                      "AA0DFE", "F8A19F", "325A9B", "C4451C", "1C8356", "85660D", 
                      "B10DA1", "FBE426", "1CBE4F", "FA0087", "FC1CBF", "F7E1A0", 
                      "C075A6", "782AB6", "AAF400", "BDCDFF", "822E1C", "B5EFB5", 
                      "7ED7D1", "1C7F93", "D85FF7", "683B79", "66B0FF", "3B00FB"),
                      
    "tol"        = c( "332288", "6699CC", "88CCEE", "44AA99", "117733", "999933", 
                      "DDCC77", "661100", "CC6677", "AA4466", "882255", "AA4499"),
                      
    "bright"     = c( "4477AA", "EE6677", "228833", "CCBB44", "66CCEE", "AA3377", 
                      "BBBBBB"),
                      
    "light"      = c( "77AADD", "EE8866", "EEDD88", "FFAABB", "99DDFF", "44BB99", 
                      "BBCC33", "AAAA00"),
                      
    "muted"      = c( "CC6677", "332288", "DDCC77", "117733", "88CCEE", "882255", 
                      "44AA99", "999933", "AA4499"),
                      
    "vibrant"    = c( "EE7733", "0077BB", "33BBEE", "EE3377", "CC3311", "009988", 
                      "BBBBBB"),
                      
    "tableau"    = c( "4E79A7", "F28E2B", "E15759", "76B7B2", "59A14F", "EDC948", 
                      "B07AA1", "FF9DA7", "9C755F", "BAB0AC"),
                      
    "classic"    = c( "1F77B4", "FF7F0E", "2CA02C", "D62728", "9467BD", "8C564B", 
                      "E377C2", "7F7F7F", "BCBD22", "17BECF"),
                      
    "alphabet"   = c( "AA0DFE", "3283FE", "85660D", "782AB6", "565656", "1C8356", 
                      "16FF32", "F7E1A0", "E2E2E2", "1CBE4F", "C4451C", "DEA0FD", 
                      "FE00FA", "325A9B", "FEAF16", "F8A19F", "90AD1C", "F6222E", 
                      "1CFFCE", "2ED9FF", "B10DA1", "C075A6", "FC1CBF", "B00068", 
                      "FBE426", "FA0087"),
                      
    "tableau20"  = c( "1F77B4", "AEC7E8", "FF7F0E", "FFBB78", "2CA02C", "98DF8A", 
                      "D62728", "FF9896", "9467BD", "C5B0D5", "8C564B", "C49C94", 
                      "E377C2", "F7B6D2", "7F7F7F", "C7C7C7", "BCBD22", "DBDB8D", 
                      "17BECF", "9EDAE5"),
                      
    "kelly"      = c( "F3C300", "875692", "F38400", "A1CAF1", "BE0032", "C2B280", 
                      "848482", "008856", "E68FAC", "0067A5", "F99379", "604E97", 
                      "F6A600", "B3446C", "DCD300", "882D17", "8DB600", "654522", 
                      "E25822", "2B3D26", "222222"),
                      
    "fishy"      = c( "6388B4", "FFAE34", "EF6F6A", "8CC2CA", "C3BC3F", "55AD89", 
                      "BB7693", "BAA094", "767676")
  )
  
  
  
  for (pal_name in names(cat)) {
    
    fp <- sprintf("inst/www/img/aes/%s.png", pal_name)
    png(filename = fp, width = 200, height = 20)
    
    pal   <- cat[[pal_name]]
    width <- 1 / length(pal)
    
    for (i in seq_along(pal)) {
      color <- paste0('#', pal[[i]])
      
      grid.rect(
        x      = width * (i - 0.5),
        width  = width, 
        y      = 0.5, 
        height = 1, 
        gp     = gpar(col = color, fill = color) )
    }
    
    dev.off()
    
    
    
    # # Individual colors
    # 
    # for (i in pal) {
    #   fp <- sprintf("inst/www/img/aes/%s.png", i)
    #   png(filename = fp, width = 40, height = 40)
    #   color <- paste0('#', i)
    # 
    #   grid.rect(
    #     x      = .5,
    #     width  = 1,
    #     y      = 0.5,
    #     height = 1,
    #     gp     = gpar(col = color, fill = color) )
    # 
    #   dev.off()
    # }
    
    
  }
  
})
  
