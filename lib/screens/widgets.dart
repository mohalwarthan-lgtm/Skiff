import 'package:flutter/material.dart';

class PosterCard extends StatefulWidget {
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
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: _card(context),
    );
  }

  Widget _card(BuildContext context) {
    return InkWell(
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                    width: 1.4,
                    color: _hover
                        ? const Color(0x8C35D6E8)
                        : Colors.transparent),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(9),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOut,
                  transformAlignment: Alignment.center,
                  // Zoom-tilt INSIDE the clip: nothing can overflow the
                  // grid cell, so no cropped shadows or titles.
                  transform: _hover
                      ? (Matrix4.identity()
                        ..setEntry(3, 2, 0.0015)
                        ..rotateX(-0.03)
                        ..rotateY(0.04)
                        ..scale(1.07))
                      : Matrix4.identity(),
                  child: Container(
                    width: double.infinity,
                    color: Theme.of(context).cardColor,
                    child: widget.poster != null
                        ? Image.network(widget.poster!,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.movie_outlined, size: 40))
                        : const Icon(Icons.movie_outlined, size: 40),
                  ),
                ),
              ),
            ),
          ),
          if (widget.progress != null && widget.progress! > 0)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: LinearProgressIndicator(
                  value: widget.progress!.clamp(0, 1), minHeight: 3),
            ),
          const SizedBox(height: 6),
          Text(widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 13)),
          if (widget.subtitle != null)
            Text(widget.subtitle!,
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
