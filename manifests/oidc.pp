# @summary OIDC login (SSO) for BastionVault: secret file + operator helper.
#
# The OIDC auth method is runtime state stored in the vault, not a config.hcl
# key, and writing it needs an authenticated token. This module never holds a
# token (see README, "What this module deliberately does NOT do"), so instead
# of applying the config itself it installs `oidc-configure`, an idempotent
# helper an operator runs once after `bvault login`. Re-run it after changing
# any `bastionvault::oidc_*` parameter.
#
# @api private
class bastionvault::oidc {
  $mount     = $bastionvault::oidc_mount
  $discovery = $bastionvault::oidc_discovery_url
  $client_id = $bastionvault::oidc_client_id

  if $discovery == undef or $client_id == undef {
    fail('bastionvault: oidc_enabled requires $oidc_discovery_url and $oidc_client_id.')
  }

  $secret_file = "${bastionvault::config_dir}/oidc-client-secret"
  $script_path = '/srv/scripts/bastionvault/oidc-configure'

  if $bastionvault::oidc_client_secret != undef {
    $_secret = $bastionvault::oidc_client_secret ? {
      Sensitive => $bastionvault::oidc_client_secret,
      default   => Sensitive($bastionvault::oidc_client_secret),
    }
    # root-only: read by the helper on the host and piped to the CLI on stdin.
    file { $secret_file:
      ensure    => file,
      owner     => 'root',
      group     => 'root',
      mode      => '0600',
      content   => $_secret,
      show_diff => false,
    }
    $_secret_arg = 'oidc_client_secret=-'
  } else {
    $_secret_arg = ''
  }

  # key=value words for `bvault write`, already shell-quoted. Built here (not in
  # the template) because EPP lambdas render undef under regent.
  $_role = $bastionvault::oidc_role_name
  $_aud  = pick($bastionvault::oidc_role_bound_audiences, [$client_id])

  $_config_words = [
    "oidc_discovery_url=${shell_escape($discovery)}",
    "oidc_client_id=${shell_escape($client_id)}",
    "oidc_scopes=${shell_escape(join($bastionvault::oidc_scopes, ','))}",
    "allowed_redirect_uris=${shell_escape(join($bastionvault::oidc_allowed_redirect_uris, ','))}",
    "default_role=${shell_escape($_role)}",
    $_secret_arg,
  ].filter |$w| { $w != '' }

  $_role_words = [
    "bound_audiences=${shell_escape(join($_aud, ','))}",
    "policies=${shell_escape(join($bastionvault::oidc_role_policies, ','))}",
    "user_claim=${shell_escape($bastionvault::oidc_role_user_claim)}",
    $bastionvault::oidc_role_groups_claim ? {
      undef   => '',
      default => "groups_claim=${shell_escape($bastionvault::oidc_role_groups_claim)}",
    },
    empty($bastionvault::oidc_role_bound_claims) ? {
      true    => '',
      default => "bound_claims=${shell_escape(stdlib::to_json($bastionvault::oidc_role_bound_claims))}",
    },
    empty($bastionvault::oidc_role_claim_mappings) ? {
      true    => '',
      default => "claim_mappings=${shell_escape(stdlib::to_json($bastionvault::oidc_role_claim_mappings))}",
    },
    $bastionvault::oidc_role_token_ttl_secs ? {
      undef   => '',
      default => "token_ttl_secs=${bastionvault::oidc_role_token_ttl_secs}",
    },
  ].filter |$w| { $w != '' }

  file { $script_path:
    ensure  => file,
    owner   => 'root',
    group   => 'root',
    mode    => '0750',
    content => epp('bastionvault/oidc-configure.sh.epp', {
        'mount'        => $mount,
        'config_words' => join($_config_words, ' '),
        'has_secret'   => $bastionvault::oidc_client_secret != undef,
        'secret_file'  => $secret_file,
        'role'         => $_role,
        'role_words'   => join($_role_words, ' '),
    }),
  }
}
