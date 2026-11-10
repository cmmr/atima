
library(ggplot2)
library(magrittr)

rand <- function (lo = 0, hi = 1, n = 8) {
  runif(n) * (hi - lo) + lo
}



#________________________________________________________
# Boxplot
#________________________________________________________

p <- list()

set.seed(1)
df <- data.frame(
  x = factor(rep(1:2, each = 10)),
  y = c(
    3.3, 3.9, 4.9, 6.5, 3.0, 6.5, 6.7, 5.3, 5.1, 2.3, 
    5.8, 5.7, 7.7, 6.5, 8.1, 7.0, 7.9, 9.0, 6.5, 8.1 ))

p[['box']]    <- ggplot(df, aes(x=x, y=y)) + geom_boxplot(color = "#659fd5", width = 0.6)
p[['dot']]    <- ggplot(df, aes(x=x, y=y)) + ggbeeswarm::geom_beeswarm(color="#659fd5", size=1, cex=8, method="center")
p[['strip']]  <- ggplot(df, aes(x=x, y=y)) + ggbeeswarm::geom_quasirandom(color="#659fd5", size=1, width = 0.25)
p[['violin']] <- ggplot(df, aes(x=x, y=y)) + geom_violin(color = "#659fd5", fill="#659fd5AA", width = 0.6)


df <- plyr::ddply(df, 'x', function (g) {
  avg <- mean(g[['y']]); dev <- sd(g[['y']])
  data.frame(y = avg, ymin = avg - dev, ymax = avg + dev)
})
p[['bar']]        <- ggplot(df, aes(x=x, y=y))                       + geom_col(fill = "#659fd5", width = 0.6)
p[['crossbar']]   <- ggplot(df, aes(x=x, y=y, ymin=ymin, ymax=ymax)) + geom_crossbar(color = "#659fd5", width = 0.6)
p[['errorbar']]   <- ggplot(df, aes(x=x,      ymin=ymin, ymax=ymax)) + geom_errorbar(color = "#659fd5", linewidth = 1, width = 0.4)
p[['linerange']]  <- ggplot(df, aes(x=x,      ymin=ymin, ymax=ymax)) + geom_linerange(color = "#659fd5", linewidth = 1.2)
p[['pointrange']] <- ggplot(df, aes(x=x, y=y, ymin=ymin, ymax=ymax)) + geom_pointrange(color = "#659fd5", linewidth = 1, size = .4)

p[['blank']] <- ggplot(df, aes(x=x, y=y)) + geom_point(color="white")


for (i in names(p)) {
  plot <- p[[i]] +
    scale_y_continuous(limits = c(0, 10)) +
    theme_void() +
    theme(plot.background = element_rect(fill = "#FFFFFF", color = NA))
  ggsave(
    sprintf("D:/Dropbox/Baylor/GitHub/atima/inst/www/img/layers/%s.png", i),
    plot = plot, width = 50, height = 50, units = "px", dpi = 72 )
}



#________________________________________________________
# Corrplot
#________________________________________________________

p <- list()

df <- data.frame(
  x     = rep(1:8, times = 2),
  y     = c(
    2.7, 3.7, 5.1, 7.0, 4.8, 8.2, 9.0, 8.4, 
    2.8, 0.8, 1.7, 1.9, 4.2, 3.3, 5.2, 4.4 ),
  group = rep(1:2, each = 8) )
df[['fit']] <- c(
  broom::augment(lm(formula = y ~ x, data = df, subset = 1:16 <= 8))[['.fitted']], 
  broom::augment(lm(formula = y ~ x, data = df, subset = 1:16 >= 9))[['.fitted']] )

p[['scatter']]    <- ggplot(df, aes(x=x, y=y)) + geom_point(color = "#659fd5", size = 1)
p[['trend']]      <- ggplot(df, aes(x=x, y=y, group=group)) + geom_smooth(color = "#659fd5", method = "lm", se = FALSE)
p[['confidence']] <- ggplot(df, aes(x=x, y=y, group=group)) + geom_smooth(fill = "#659fd5", method = "lm", color = NA)
p[['residual']]   <- ggplot(df, aes(x=x, y=y)) + 
  geom_smooth(mapping = aes(group=group), color = "lightgray", method = "lm", se = FALSE, size = .5) + 
  geom_segment(mapping = aes(xend=x, yend=fit), color = "#659fd5", size = 1)


for (i in names(p)) {
  plot <- p[[i]] +
    scale_x_continuous(limits = c(0, 10)) +
    scale_y_continuous(limits = c(0, 10)) +
    theme_void() +
    theme(plot.background = element_rect(fill = "#FFFFFF", color = NA))
  ggsave(
    sprintf("D:/Dropbox/Baylor/GitHub/atima/inst/www/img/layers/%s.png", i),
    plot = plot, width = 50, height = 50, units = "px", dpi = 72 )
}



#________________________________________________________
# BiPlot
#________________________________________________________

p <- list()

df_samples <- data.frame(
  x     = c(1.6, 1.8, 3.4, 5.4, 6.0, 9.5, 9.7, 7.8),
  y     = c(3.8, 0.4, 1.2, 1.1, 7.8, 6.3, 8.8, 7.5),
  label = c('1', '2', '3', '4', '5', '6', '7', '8'),
  group = c(1, 1, 1, 1, 2, 2, 2, 2) ) %>% 
  
  plyr::ddply('group', function (g) {
    g[['xend']] <- mean(g[['x']])
    g[['yend']] <- mean(g[['y']])
    return (g)
  })


df_taxa <- data.frame(
  x       = c(1, 4, 9),
  y       = c(3, 0, 8),
  size    = c(4, 8, 6),
  label   = paste0("Taxa", 1:3),
  label_x = c(3, 4.5, 8),
  label_y = c(3, -0.5, 8)
)


p[['point']] <- ggplot() + 
  geom_point(
    data    = df_samples, 
    mapping = aes(x=x, y=y), 
    color   = "#659fd5", 
    size    = 1 )

p[['ellipse']] <- ggplot() + 
  stat_ellipse(
    data    = df_samples, 
    mapping = aes(x=x, y=y, group=group), 
    color   = "#659fd5", 
    level   = 0.9, 
    size    = 1 )

p[['spider']] <- ggplot() + 
  geom_segment(
    data    = df_samples,
    mapping = aes(x=x, y=y, xend=xend, yend=yend), 
    color   = "#659fd5", 
    size    = .75 )

p[['name']] <- ggplot() + 
  geom_text(
    data     = df_samples,
    mapping  = aes(x=x, y=y, label=label), 
    color    = "#659fd5", 
    size     = 3.5, 
    fontface = "bold" )

p[['mean']] <- ggplot() + 
  geom_point(
    data        = df_taxa, 
    mapping     = aes(x=x, y=y,size=size), 
    color       = "#659fd5", 
    alpha       = 0.5, 
    show.legend = FALSE ) +
  scale_size(range = c(3, 8))

p[['arrow']] <- ggplot() + 
  geom_segment(
    data    = df_taxa, 
    mapping = aes(x=x, y=y, xend=5, yend=5), 
    color   = "#659fd5", 
    size    = .75, 
    arrow   = grid::arrow(ends = "first", type = "closed", length = unit(0.1, "npc")) )

p[['taxon']] <- ggplot() + 
  geom_label(
    data          = df_taxa, 
    mapping       = aes(x=label_x, y=label_y, label=label), 
    color         = "#659fd5", 
    size          = 3.5, 
    fontface      = "bold",
    label.padding = grid::unit(".1", "lines") )




for (i in names(p)) {
  plot <- p[[i]] +
    scale_x_continuous(limits = c(-2, 13)) +
    scale_y_continuous(limits = c(-3, 11)) +
    theme_void() +
    theme(plot.background = element_rect(fill = "#FFFFFF", color = NA))
  ggsave(
    sprintf("D:/Dropbox/Baylor/GitHub/atima/inst/www/img/layers/%s.png", i),
    plot = plot, width = 50, height = 50, units = "px", dpi = 72 )
}

