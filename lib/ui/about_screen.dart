import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'components.dart';
import 'theme.dart';

/// The app version shown in About (keep in step with pubspec.yaml).
const appVersion = '1.0.3';

/// A small About page: what the app is, who made it, and the licences.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  static const _links = [
    ('GitHub', 'isg32', 'https://github.com/isg32'),
    (
      'LinkedIn',
      'sapangajjar101105',
      'https://www.linkedin.com/in/sapangajjar101105/',
    ),
    ('Source', 'openhd350b', 'https://github.com/isg32/openhd350b'),
  ];

  static const _licences = [
    ('flutter_blue_plus', 'BSD-3 / FlutterBluePlus'),
    ('pointycastle', 'MIT'),
    ('archive', 'MIT'),
    ('http', 'BSD-3'),
    ('share_plus', 'BSD-3'),
    ('permission_handler', 'MIT'),
  ];

  Future<void> _open(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          _AppMark(),
          const SizedBox(height: 16),
          SectionCard(
            title: 'About',
            icon: Icons.headphones,
            child: Text(
              'An open-source replacement for Sennheiser Smart Control, for the '
              'HD 350BT. Reverse-engineered for interoperability and repair of '
              'hardware you own. Installs official signed firmware only; no '
              'account, no tracking, nothing sent anywhere but Sennheiser\'s '
              'firmware cloud.',
              style: context.texts.bodyMedium,
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Developer',
            icon: Icons.person_outline,
            child: Column(
              children: [
                Row(
                  children: [
                    ClipOval(
                      child: Image.asset(
                        'assets/images/developer.jpg',
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Sapan Gajjar',
                            style: context.texts.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            'Made this app',
                            style: context.texts.bodySmall?.copyWith(
                              color: context.colors.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                for (final (title, handle, url) in _links)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    leading: Icon(switch (title) {
                      'GitHub' || 'Source' => Icons.code,
                      _ => Icons.link,
                    }),
                    title: Text(title),
                    subtitle: Text(handle),
                    trailing: const Icon(Icons.open_in_new, size: 18),
                    onTap: () => _open(url),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          SectionCard(
            title: 'Open-source licences',
            icon: Icons.description_outlined,
            child: Column(
              children: [
                for (final (name, licence) in _licences)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(name, style: context.texts.bodyMedium),
                        Text(
                          licence,
                          style: context.texts.bodySmall?.copyWith(
                            color: context.colors.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Not affiliated with or endorsed by Sennheiser. Product names and '
            'images belong to their respective owners.',
            textAlign: TextAlign.center,
            style: context.texts.bodySmall?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _AppMark extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        SizedBox(
          height: 120,
          child: Image.asset('assets/images/hd350bt.png', fit: BoxFit.contain),
        ),
        const SizedBox(height: 12),
        Text(
          'OpenHD350B',
          style: context.texts.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        Text(
          'Version $appVersion',
          style: context.texts.bodySmall?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}
