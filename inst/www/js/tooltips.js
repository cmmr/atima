//___________________________________________________________________
// Tooltips for controls' labels.
//___________________________________________________________________
const TOOLTIPS = {
  'x-Axis'      : 'Metadata variable to place on the plot\'s x-axis.',
  'Stat By'     : 'Metadata variable defining the statistical groups.',
  'Limit By'    : 'Only keep samples that match this criteria.',
  'Label By'    : 'What values should be used for labeling the x-axis?',
  'Color By'    : 'Color samples according to metadata.',
  'Pattern By'  : 'Specify different fill patterns based on metadata.',
  'Shape By'    : 'Specify different shapes for points based on metadata.',
  'Order By'    : 'How should samples be positioned along the x-axis?',
  'Facet By'    : 'Create sub-plots for groups defined in the metadata.',
  'Rank'        : 'Taxonomic rank at which to summarize count data.',
  'Ordination'  : 'Method for reducing N-dimensional count matrix to x/y coordinates.',
  'Grid'        : 'Control clustering and color coding of numeric values.',
  'Margins'     : 'What to display in the top and/or left margins of the figure.',
  'hm_tracks'   : 'Metadata variable(s) to display as a color-coded track.',
  'Fit'         : 'Expected relationship between test and response values.',
  'Zoom'        : 'Increase or decrease the size of all elements in the figure.',
  'Width'       : 'Width of the figure in pixels. Resize browser window to reset.',
  'Height'      : 'Height of the figure in pixels. Resize browser window to reset.',
  'Plot Design' : 'Select the type(s) of plot to use for this figure.',
  'Depth'       : 'How many sequencing reads per sample to keep.',
  'Weighted'    : 'Consider abundance in addition to presence/absence.',
  'adiv_metric' : 'Alpha diversity algorithm to use.',
  'bdiv_metric' : 'Beta diversity algorithm to use.',
  'Level'       : 'Shade area around the trendline for a given confidence level.',
  'taxa_min_ab' : 'Only consider taxa at or above this mean relative abundance.',
  'Flip'        : 'Rotate plot 90 degrees.',
  'Stripe'      : 'Shade the background of every other column/row.',
  'Test'        : 'What to test for significance.',
  'Stats'       : 'Display adjusted p-values on the figure.',
  'Compare'     : 'Each beta diversity value is derived from a pair of samples.\n' +
                  'within groups = Only use sample pairs from the same group.\n' +
                  'between groups = Only use sample pairs from different groups.',
  'stat'        : 'Kruskal-Wallis rank sum statistic. Closer to zero = less significant.',
  'mean'        : 'Estimated marginal mean, aka least-squares mean.',
  'mean_diff'   : 'Difference in means.',
  'slope'       : 'The slope of the trend line. A horizontal line has slope=0.',
  'slope_diff'  : 'Difference in slopes.',
  'h1'          : 'Alternate hypothesis (relative to preceding column).',
  'p_val'       : 'Probability that null hypothesis is correct.',
  'adj_p'       : 'p_val after correcting for the false discovery rate as per Benjamini & Hochberg (1995).',
  'effect_size' : 'Observed difference, divided by the population SD. (Cohen\'s d)',
  'lower'       : 'Lower bound on the confidence interval, as selected at right.',
  'upper'       : 'Upper bound on the confidence interval, as selected at right.',
  'se'          : 'Standard error. SE = sample_std_dev / n_samples',
  'n'           : 'Number of samples.',
  'df'          : 'Degrees of freedom.',
  't_ratio'     : 'How many standard errors the estimate (mean, mean_diff, slope, or slope_diff) is away from 0.',
  'z'           : 'Standardized effect size (SES).',
  'r_sqr'       : 'Percent of variation explained by the model.',
  'adj_r'       : 'r_sqr, taking degrees of freedom into account.',
  'aic'         : 'Akaike Information Criterion (predictive models).',
  'bic'         : 'Bayesian Information Criterion (descriptive models).',
  'loglik'      : 'Log-likelihood goodness-of-fit score.',
  'fit_p'       : 'P-value for observing this fit by chance.'
};



function find_tooltip (p) {
  if (p['tt'])                                return p['tt'];
  if (p['sync_id'] && TOOLTIPS[p['sync_id']]) return TOOLTIPS[p['sync_id']];
  if (p['param']   && TOOLTIPS[p['param']])   return TOOLTIPS[p['param']];
  if (p['label']   && TOOLTIPS[p['label']])   return TOOLTIPS[p['label']];
  return undefined;
};
