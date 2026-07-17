import 'package:flutter/material.dart';

class PosterCard extends StatelessWidget {
  final String? poster;
  final String title;
  final String? subtitle;
  final double? progress; // 0..1 bar under the poster
  final VoidCallback onTap;

  const PosterCard({
    super.key,
    required this.title,
    required this.onTap,
    this.poster,
    this.subtitle,
    this.progress,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: double.infinity,
                color: Theme.of(context).cardColor,
                child: poster != null
                    ? Image.network(poster!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) =>
                            const Icon(Icons.movie_outlined, size: 40))
                    : const Icon(Icons.movie_outlined, size: 40),
              ),
            ),
          ),
          if (progress != null && progress! > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                  value: progress!.clamp(0, 1), minHeight: 3),
            ),
          const SizedBox(height: 6),
          Text(title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13)),
          if (subtitle != null)
            Text(subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11, color: Theme.of(context).hintColor)),
        ],
      ),
    );
  }
}

class PosterGrid extends StatelessWidget {
  final List<Widget> children;
  final bool shrinkWrap;
  final ScrollController? controller;
  const PosterGrid(
      {super.key,
      required this.children,
      this.shrinkWrap = false,
      this.controller});

  @override
  Widget build(BuildContext context) => GridView.count(
        controller: controller,
        crossAxisCount: (MediaQuery.of(context).size.width / 170).floor().clamp(2, 10),
        childAspectRatio: 0.58,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        padding: const EdgeInsets.all(18),
        shrinkWrap: shrinkWrap,
        physics: shrinkWrap ? const NeverScrollableScrollPhysics() : null,
        children: children,
      );
}
