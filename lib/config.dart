/// Build-time configuration.
///
/// Trakt app credentials can be baked in by the cloud build
/// (repository secrets TRAKT_CLIENT_ID / TRAKT_CLIENT_SECRET). If absent,
/// the Settings screen asks for them once and stores them locally.
class Config {
  static const traktClientId = String.fromEnvironment('TRAKT_CLIENT_ID');
  static const traktClientSecret = String.fromEnvironment('TRAKT_CLIENT_SECRET');
  static bool get hasBundledTrakt =>
      traktClientId.isNotEmpty && traktClientSecret.isNotEmpty;
}

/// Library shelves. Keys are stored in the database and mirrored to Trakt
/// (plan -> watchlist), so don't rename them.
const statuses = <(String, String)>[
  ('watching', 'Watching'),
  ('plan', 'Plan to watch'),
  ('completed', 'Completed'),
];

String statusLabel(String key) =>
    statuses.firstWhere((s) => s.$1 == key, orElse: () => (key, key)).$2;
