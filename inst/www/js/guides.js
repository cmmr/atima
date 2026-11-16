// Notes on choosing: a few sentences, in plain words, for the choices
// people ask about most. What an option of rbiom does is that option's
// help, which comes from rbiom with the schema; these notes are about
// choosing between options, and each ends with a link to rbiom's own
// documentation. This file is pure (no page, no imports), so the tests
// can run it.
//
// The notes say what rbiom does. When rbiom changes (a default, a test, a
// method), change them with it. Controls are named by the labels atima
// gives them (`schema_labels` in R/schema.R).

const RBIOM = 'https://cmmr.github.io/rbiom/reference/';

/**
 * The notes, by key. `title` is a question; `text` its answer, a
 * paragraph per entry; `more` the page of rbiom's documentation to read on.
 */
export const GUIDES = {

  adiv: {
    title: 'Which alpha diversity metric?',
    text: [
      'Alpha diversity is one number for each sample. Some metrics count how many kinds of organisms a sample holds (richness); others also ask how evenly its reads are spread over them.',
      'Observed Features is the number of kinds seen. Chao1 and ACE estimate how many there are in all, including those too rare to have been seen; they work from the kinds seen only a few times, those seen once above all, so they say little when the counts were denoised in a way that removes those.',
      'Shannon and the Simpson indices take evenness into account as well: a sample that one organism dominates scores low, however many others it holds. The Simpson indices follow the most common organisms; Shannon gives the rare ones more say.',
      "Faith's Phylogenetic Diversity adds up the branches of the tree that a sample's organisms cover, so close relatives add less than distant ones. It is offered when the project has a phylogenetic tree.",
      'Shannon is the default. To report two, take one of each kind, such as Observed Features and Shannon: together they show whether groups differ in how many organisms they hold or in how these are balanced. Choose the metric before you look at the p-values, not after.',
    ],
    more: { label: 'Alpha diversity in rbiom', href: `${RBIOM}adiv_table.html` },
  },

  bdiv: {
    title: 'Which beta diversity metric?',
    text: [
      'Beta diversity is a distance between two samples: zero when their communities are the same, larger the more they differ. The metrics differ in what they count as a difference.',
      'Bray-Curtis, the default, compares how abundant each organism is in the two samples. Jaccard and Dice-Sorensen look only at which organisms are present, so a rare organism counts as much as a common one.',
      'The UniFrac metrics use the phylogenetic tree: two samples whose organisms are close relatives are nearer than two with unrelated ones. Unweighted UniFrac looks at presence only; Weighted UniFrac takes abundance into account; Generalized UniFrac lets "UniFrac alpha" (under Advanced) set how much weight abundance gets. They are offered when the project has a tree.',
      'Aitchison distance comes from compositional data analysis: it compares the ratios between organisms (centred log-ratios), not their shares.',
      'No metric is the right one. A difference that shows with a metric of abundance and with a metric of presence is on firmer ground than one that shows with a single metric. Choose the metric before you look at the p-values.',
    ],
    more: { label: 'Beta diversity in rbiom', href: `${RBIOM}bdiv_table.html` },
  },

  depth: {
    title: 'Rarefy, and to what depth?',
    text: [
      'Samples are not sequenced equally deeply, and a sample with more reads shows more organisms. Rarefying takes the same number of reads, at random, from every sample, so that samples are compared like with like. Samples with fewer reads than the depth are left out. Rarefying throws reads away, and not every statistician agrees that it should be done; but diversity depends on the number of reads, and rarefying is the plain way to take that out.',
      'The depths offered are the read counts of the samples: choosing one keeps that sample and every sample with more reads. A higher depth keeps more of each sample and drops more samples; a lower one keeps more samples and less of each. An uploaded project starts at the lowest depth that still keeps a tenth of all the reads.',
      'The pages under Rarefaction show the trade-off. The curves show whether diversity has levelled off at a depth; "Reads per sample" shows each sample\'s reads, with a line at a depth and how many samples and reads it keeps.',
      'The alpha diversity, beta diversity and taxa abundance figures are made from the rarefied counts. The rarefaction figures and the differential abundance forest plot (LinDA) use all reads, whatever the depth.',
      'The same reads are drawn every time, so a figure does not change when it is drawn again. The depth belongs to the project: every figure follows it.',
    ],
    more: { label: 'Rarefying in rbiom', href: `${RBIOM}rarefy.html` },
  },

  ord: {
    title: 'Which ordination?',
    text: [
      'An ordination puts the samples on a plane so that samples with similar communities lie near each other. The statistics are computed from the distances between the samples, not from the picture: they are the same whichever ordination is shown.',
      'PCoA, the default, keeps the distances themselves as well as two axes can, and each axis says what percentage of the variation it shows.',
      'NMDS keeps only the order of the distances: which pairs of samples are closer than which. It can show structure that PCoA flattens, but the scale of its axes means nothing. The caption gives its stress, how badly the picture fits the distances. By a common rule of thumb (Clarke 1993), below 0.1 is a good fit, up to 0.2 the overall picture can be used but not its details, and near 0.3 it is close to arbitrary.',
      't-SNE and UMAP, offered when their R packages are installed, pull similar samples into tight clusters. They are good for seeing whether there are groups, but the sizes of the clusters and the distances between them mean little, and the picture changes with "Random seed" (under Advanced). Use them to explore.',
    ],
    more: { label: 'Ordination in rbiom', href: `${RBIOM}bdiv_ord_plot.html` },
  },

  test_groups: {
    title: 'Which statistical test?',
    text: [
      'The automatic choice suits most figures. When "Compare groups" is the field on the x-axis, each pair of groups is compared with a Mann-Whitney U test (wilcox). When groups are compared within each category of the x-axis, a Kruskal-Wallis test asks whether any of them differs from the rest; that comparison is always made with Kruskal-Wallis.',
      'Both are rank tests: they make no assumption about the shape of the distribution, which suits diversity values and abundances.',
      'emmeans fits a linear model and compares the estimated means of the groups. It expects values spread roughly normally around each mean; "Transform values" (under Advanced) can help. When "Block by" names a subject that was sampled more than once, the automatic choice is emmeans, with the subject in the model: the rank tests cannot take that into account.',
      'P-values are adjusted for the number of comparisons made ("P adjustment", under Advanced).',
      'On the taxa abundance box plot each taxon is tested on its own. To ask which taxa differ between groups, the differential abundance forest plot (LinDA) is the better tool: it allows for the fact that abundances are shares of a whole.',
    ],
    more: { label: 'Statistics in rbiom', href: `${RBIOM}stats_table.html` },
  },

  test_trend: {
    title: 'Which statistical test?',
    text: [
      'These figures fit a trend line through the values along the x-axis, and the test is made on the fitted model.',
      'With no groups, emmeans asks whether the values change along the x-axis at all, and emtrends tests the slope.',
      'With groups to compare, emmeans asks whether the groups differ in their mean value at one position along the x-axis, and emtrends whether their trend lines differ in slope. The position is the median of the x-axis values unless "Evaluate at" (under Advanced) gives another.',
      '"Trend line" (under Advanced) sets the shape: lm a straight line, log a straight line against the logarithm of the x-axis, gam a smooth curve. A straight line has one slope, which is easy to report; a curve follows the data where the relationship is not straight, and its slope is taken at the position above.',
    ],
    more: { label: 'Statistics in rbiom', href: `${RBIOM}stats_table.html` },
  },

  test_distance: {
    title: 'Which statistical test?',
    text: [
      'These tests ask whether groups of samples differ in their communities. They are made on the samples\' distances to each other, not on what the figure draws. They shuffle the group labels many times and count how often a difference as large as the real one arises by chance, so the smallest p-value possible depends on the number of permutations: 0.001 with 999 ("Permutations", under Advanced).',
      'PERMANOVA (adonis2), the default, asks whether samples are more alike within a group than between groups. Its R-squared is the share of the variation that the groups account for.',
      'PERMANOVA can also be significant when the groups differ only in how spread out they are. betadisper tests exactly that: whether some groups vary more than others. A significant PERMANOVA with a betadisper that is not significant points to a difference in composition.',
      'MRPP is an older test of the same question as PERMANOVA.',
      'When "Block by" names a subject that was sampled more than once, the labels are shuffled only within each subject.',
    ],
    more: { label: 'Beta diversity statistics in rbiom', href: `${RBIOM}bdiv_stats.html` },
  },

  test_mantel: {
    title: 'What does the Mantel test say?',
    text: [
      'The Mantel test asks whether pairs of samples that are further apart in the numeric field also differ more in their communities. It correlates the two sets of distances, and shuffles the samples many times to see how often a correlation as strong arises by chance.',
      'The trend line is drawn through the pairs of samples to show the relationship; the p-value comes from the Mantel test, not from the line.',
      'A significant result says that the communities change along the field. It does not say which organisms change: the taxa abundance pages do.',
    ],
    more: { label: 'Beta diversity statistics in rbiom', href: `${RBIOM}bdiv_stats.html` },
  },

  da: {
    title: 'Why LinDA, and not LEfSe?',
    text: [
      'Both look for the taxa that differ between groups. LEfSe runs rank tests on relative abundances and ranks the taxa that pass by an LDA score.',
      'Relative abundances are shares of a whole. When one taxon grows, the shares of all the others shrink, although their amounts did not change. A test that looks at each share on its own can therefore report differences that are not there.',
      'LinDA (Zhou et al. 2022) is built for this. It fits a linear model to each taxon\'s centred log-ratios, and removes the shift that the shared whole adds to every taxon\'s estimate, assuming that most taxa do not change. It adjusts the p-values for the number of taxa tested, and can take other fields ("Adjust for") and repeated samples of one subject ("Block by") into account. For every taxon it reports a log2 fold change with a confidence interval: how large the difference is, not only whether there is one.',
      'LinDA uses all reads, not the rarefied counts: it allows for sequencing depth itself. Taxa found in fewer samples than "Min. prevalence" are not tested.',
      'For a rank test of each taxon on its own, the taxa abundance box plot offers Kruskal-Wallis and Mann-Whitney U tests, with adjusted p-values. No method is right for every dataset: a finding that matters is worth confirming with a second method.',
    ],
    more: { label: 'Differential abundance in rbiom', href: `${RBIOM}taxa_da.html` },
  },
};

/** Does a parameter offer this choice? */
const offers = (p, choice) => Array.isArray(p.choices) && p.choices.includes(choice);

/**
 * The note for a parameter of a function, by what the parameter is and
 * offers, not by which function it belongs to.
 * @return {string|null} A key of GUIDES.
 */
export function paramGuide(p) {
  if (p.type === 'metric') return p.div === 'alpha' ? 'adiv' : p.div === 'beta' ? 'bdiv' : null;
  if (p.name === 'ord' && offers(p, 'NMDS')) return 'ord';
  if (p.name === 'method' && offers(p, 'linda')) return 'da';
  if (p.name === 'test') {
    if (offers(p, 'wilcox'))   return 'test_groups';
    if (offers(p, 'emtrends')) return 'test_trend';
    if (offers(p, 'adonis2'))  return 'test_distance';
    if (offers(p, 'mantel'))   return 'test_mantel';
  }
  return null;
}

/**
 * The note for a function as a whole, shown under its name: one whose
 * parameter is tucked away under Advanced but is the first question
 * people ask about the figure.
 * @return {string|null} A key of GUIDES.
 */
export function functionGuide(def) {
  return def.params.some(p => paramGuide(p) === 'da') ? 'da' : null;
}
