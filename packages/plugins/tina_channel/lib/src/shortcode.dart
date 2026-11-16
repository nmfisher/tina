/// Agent shortcode identity: `adjective-noun` names like `calm-heron`,
/// drawn uniformly at random once per session. The lists are curated by
/// hand — all lowercase ASCII, no duplicates, no word a prefix of
/// another word in either list (so a spoken or transcribed name is
/// unambiguous), nothing awkward to read aloud. This is user-facing.
///
/// Collision avoidance: before settling, the caller checks the channel
/// store's ACTIVE member rows (status other than `left`) and redraws;
/// after bounded retries a short numeric suffix is appended. Two
/// processes starting side by side on one workspace land on different
/// names with overwhelming probability, and the store check closes the
/// rest.
library;

import 'dart:math';

import '../channel_store_api.dart';

/// Hand-curated adjectives (identity prefixes), lowercase ASCII only.
const List<String> shortcodeAdjectives = [
  'amber', 'ancient', 'angular', 'arctic', 'ashen', 'austere', 'autumn',
  'azure', 'balanced', 'barren', 'beaming', 'benthic', 'blithe', 'bold',
  'breezy', 'brilliant', 'brisk', 'bronze', 'buoyant', 'burly', 'calm',
  'candid', 'cardinal', 'celestial', 'chalk', 'cheerful', 'chill',
  'chiseled', 'civil', 'classic', 'clear', 'clever', 'cobalt', 'cogent',
  'composed', 'cordial', 'crimson', 'crisp', 'dapper', 'daring', 'deft',
  'dense', 'devoted', 'diligent', 'diverse', 'dulcet', 'eager', 'earnest',
  'ebony', 'eclectic', 'effusive', 'electric', 'eminent', 'endless',
  'energetic', 'ethereal', 'faithful', 'fearless', 'ferric', 'fluent',
  'focused', 'fragrant', 'frank', 'gallant', 'gentle', 'ginger',
  'glacial', 'gleaming', 'glowing', 'golden', 'granite', 'gravel',
  'halcyon', 'hardy', 'harmonious', 'heroic', 'honest', 'humble',
  'illustrious', 'indigo', 'inland', 'ivory', 'jasper', 'jolly',
  'jubilant', 'keen', 'lambent', 'lateral', 'leafy', 'level', 'linen',
  'lively', 'lofty', 'lucid', 'luminous', 'lunar', 'lush', 'magenta',
  'magnetic', 'majestic', 'mellow', 'merry', 'meticulous', 'mild',
  'mindful', 'modest', 'mossy', 'mottled', 'noble', 'northern', 'novel',
  'observant', 'olive', 'opaline', 'orbital', 'patient', 'pellucid',
  'perceptive', 'pewter', 'poetic', 'precise', 'princely', 'private',
  'profound', 'proud', 'prudent', 'punctual', 'quaint', 'radiant',
  'rational', 'refined', 'regal', 'reliable', 'resolute', 'rosy',
  'rugged', 'rustic', 'saffron', 'sandy', 'sapphire', 'scarlet',
  'scenic', 'sedate', 'serene', 'silken', 'sleek', 'slender', 'smart',
  'smoky', 'smooth', 'snowy', 'solemn', 'sonorous', 'spry', 'stellar',
  'stern', 'sublime', 'subtle', 'sunny', 'supple', 'svelte', 'swift',
  'sylvan', 'tacit', 'tangerine', 'tangible', 'tawny', 'tender',
  'thorough', 'tidal', 'towering', 'tranquil', 'trusty', 'undaunted',
  'upland', 'valiant', 'verdant', 'vernal', 'versatile', 'vibrant',
  'vigilant', 'virtuous', 'vivid', 'warm', 'westerly', 'whimsical',
  'willowy', 'wintry', 'wistful', 'witty', 'worthy', 'xanthic',
  'yeasty', 'zesty', 'zingy',
];

/// Hand-curated nouns (identity suffixes), lowercase ASCII only.
const List<String> shortcodeNouns = [
  'acorn', 'albatross', 'almond', 'anchovy', 'anemone', 'antler',
  'archer', 'armadillo', 'arrow', 'artichoke', 'atlas', 'avocet',
  'badger', 'bagpipe', 'bamboo', 'banjo', 'basil', 'bassoon', 'baton',
  'beacon', 'beagle', 'beaver', 'bedrock', 'beetle', 'bellows',
  'bicycle', 'bison', 'blackbird', 'bobcat', 'bonfire', 'bonsai',
  'bookworm', 'borzoi', 'bramble', 'breeze', 'bronco', 'broom',
  'buffalo', 'bugle', 'bunker', 'cacao', 'cairn', 'canary', 'canoe',
  'canvas', 'capybara', 'caracal', 'cardamom', 'cargo', 'carnation',
  'cascade', 'cashmere', 'cassowary', 'catfish', 'cello', 'chamois',
  'chapel', 'chickadee', 'chinchilla', 'chipmunk', 'citrus', 'civet',
  'clarinet', 'cobblestone', 'cocoa', 'coconut', 'comet', 'compass',
  'condor', 'conifer', 'copperhead', 'cormorant', 'cornet', 'cottage',
  'cougar', 'coyote', 'crane', 'crayfish', 'cricket', 'crocus',
  'cuckoo', 'currant', 'dagger', 'dahlia', 'dandelion', 'diamond',
  'dingo', 'distaff', 'dogwood', 'dolphin', 'domino', 'donkey',
  'dormouse', 'dragonfly', 'driftwood', 'duckling', 'dynamo', 'eagle',
  'easel', 'echidna', 'eider', 'ember', 'emerald', 'ermine', 'estuary',
  'eucalyptus', 'falcon', 'farrier', 'fennec', 'ferry', 'fiddler',
  'finch', 'firefly', 'flamingo', 'flounder', 'flute', 'fountain',
  'foxglove', 'freighter', 'frigate', 'fulmar', 'gannet', 'garland',
  'gecko', 'gentian', 'gibbon', 'giraffe', 'glacier', 'gnome',
  'goblet', 'goldfinch', 'goshawk', 'grebe', 'griffin', 'grouper',
  'guanaco', 'hermit', 'heron', 'hedgehog', 'hickory', 'hornbeam',
  'hornet', 'hound', 'hummingbird', 'ibex', 'ibis', 'iguana', 'impala',
  'inlet', 'jackal', 'jaguar', 'jellyfish', 'jetty', 'juniper',
  'kestrel', 'ketch', 'kingfisher', 'kinkajou', 'kitten', 'kudu',
  'ladybird', 'larch', 'larkspur', 'lemming', 'lemur', 'leopard',
  'lizard', 'llama', 'lobster', 'locust', 'loris', 'lotus', 'lyrebird',
  'macaque', 'mackerel', 'magpie', 'mallard', 'mamba', 'mammoth',
  'mandolin', 'mango', 'marlin', 'marmoset', 'marmot', 'mastodon',
  'mayfly', 'meadowlark', 'merlin', 'minnow', 'mistletoe', 'moccasin',
  'monsoon', 'moose', 'morel', 'moth', 'mullet', 'muskox', 'muskrat',
  'mynah', 'myrtle', 'narwhal', 'nautilus', 'nectarine', 'nettle',
  'newt', 'nuthatch', 'nutmeg', 'ocelot', 'okapi', 'oleander',
  'opossum', 'orangutan', 'orca', 'orchid', 'osprey', 'ostrich',
  'otter', 'oyster', 'peacock', 'peccary', 'pelican', 'penguin',
  'periwinkle', 'petrel', 'pheasant', 'phoebe', 'piano', 'pigeon',
  'pilgrim', 'pintail', 'pipit', 'pistachio', 'platypus', 'plover',
  'polecat', 'pomegranate', 'pony', 'poplar', 'porcupine', 'porpoise',
  'prawn', 'primrose', 'ptarmigan', 'puffin', 'python', 'quagga',
  'quail', 'quince', 'raccoon', 'radish', 'raven', 'redstart',
  'reindeer', 'rhubarb', 'roadrunner', 'robin', 'rockfish', 'rooster',
  'rosefinch', 'rosewood', 'sable', 'sailfish', 'salmon', 'sandpiper',
  'sardine', 'sassafras', 'sawfish', 'scallop', 'scarab', 'scoter',
  'seahorse', 'shearwater', 'shelduck', 'shrike', 'siskin', 'skimmer',
  'skink', 'skua', 'skylark', 'smelt', 'snipe', 'soapstone',
  'solitaire', 'songbird', 'sparrow', 'spoonbill', 'springbok',
  'starfish', 'stilt', 'stork', 'sunfish', 'sycamore', 'tanager',
  'tapir', 'tarsier', 'tern', 'terrapin', 'thrasher', 'thrush',
  'tigerfish', 'tilapia', 'toad', 'toucan', 'towhee', 'treefrog',
  'trout', 'trumpeter', 'tuna', 'turaco', 'turkey', 'turnstone',
  'turtle', 'vervet', 'vireo', 'viscacha', 'vole', 'vulture',
  'walleye', 'walrus', 'warbler', 'warthog', 'wasp', 'waterfall',
  'waxwing', 'weasel', 'whale', 'wheat', 'whimbrel', 'whippet',
  'widgeon', 'wildcat', 'wildebeest', 'willet', 'windflower',
  'wolfhound', 'wolverine', 'wombat', 'woodchuck', 'woodcock',
  'woodpecker', 'wren', 'wryneck', 'yellowhammer', 'zebra',
  'zigzag', 'zinnia',
];

/// Draws one uniform `adjective-noun` shortcode. Pure: pass the
/// [random] source; sessions pass their own so nothing global is
/// shared.
String generateShortcode([Random? random]) {
  final source = random ?? Random();
  final adjective = shortcodeAdjectives[
      source.nextInt(shortcodeAdjectives.length)];
  final noun = shortcodeNouns[source.nextInt(shortcodeNouns.length)];
  return '$adjective-$noun';
}

/// Whether [name] could be a bare generated shortcode (no suffix).
bool isBareShortcode(String name) =>
    RegExp(r'^[a-z]+-[a-z]+$').hasMatch(name);

/// Whether a member row counts as ACTIVE for collision purposes: any
/// status other than `left`.
bool _isActiveMember(ChannelMember member) => member.status != 'left';

/// Draws a shortcode not held by any ACTIVE member of any channel in
/// [store] (one database = one identity namespace). Up to [retries]
/// redraws; then a short numeric suffix is appended until unique.
/// Returns the settled name.
String settleAgentName(ChannelStoreApi store, [Random? random]) {
  final source = random ?? Random();
  final taken = <String>{};
  for (final channel in store.listChannels()) {
    for (final member in store.members(channel.name)) {
      if (_isActiveMember(member)) taken.add(member.name);
    }
  }
  for (var attempt = 0; attempt < 8; attempt++) {
    final candidate = generateShortcode(source);
    if (!taken.contains(candidate)) return candidate;
  }
  // Bounded retries exhausted (a store this crowded is a signal, not a
  // normal state): suffix until unique.
  var suffix = 2;
  while (true) {
    final candidate = '${generateShortcode(source)}-$suffix';
    if (!taken.contains(candidate)) return candidate;
    suffix++;
  }
}

/// The explicit-identity override from an environment mapping (the
/// composition root passes `Platform.environment`): a nonempty
/// `TINA_AGENT_NAME` wins verbatim, everything else means generate.
String? agentNameFromEnvironment(Map<String, String> environment) {
  final value = environment['TINA_AGENT_NAME']?.trim();
  return value == null || value.isEmpty ? null : value;
}
