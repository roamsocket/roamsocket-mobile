package app.roamsocket.android.ui.study

import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.ChevronRight
import androidx.compose.material.icons.outlined.Layers
import androidx.compose.material.icons.outlined.Star
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.roamsocket.android.ui.theme.Palette
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Study mode home — redesigned to match the iOS browser aesthetic:
 * pure black background, pastel blue accent (#8AB4F8), centered layout,
 * clean header with model picker pill.
 *
 * Ports [FlashcardDecksListView] from iOS `FlashcardDecksListView.swift`.
 */
@Composable
fun StudyScreen(
    onBack: () -> Unit,
    onOpenDeck: (String) -> Unit,
    onScan: () -> Unit,
    deckStore: FlashcardDeckStore,
) {
    var decks by remember { mutableStateOf(deckStore.sortedDecks) }

    LaunchedEffect(deckStore.decks.value) {
        deckStore.decks.collect { decks = it.sortedByDescending { d -> d.updatedAt } }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Palette.Background)
            .statusBarsPadding()
            .navigationBarsPadding(),
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 20.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            // Header: "Study" + model pill
            item {
                HeaderBar(onBack = onBack)
            }

            // Main CTA: sparkle icon + title + subtitle
            item {
                ScanQuestionsCTA(
                    onClick = onScan,
                    modifier = Modifier.padding(top = 24.dp),
                )
            }

            // Guided learning CTA
            item {
                GuidedLearningCTA(
                    onClick = { /* TODO: guided learning */ },
                )
            }

            // Decks section
            item {
                Spacer(modifier = Modifier.height(8.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        text = "Decks",
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.SemiBold,
                        color = Palette.TextSecondary,
                    )
                    if (decks.isNotEmpty()) {
                        Text(
                            text = "${decks.size}",
                            style = MaterialTheme.typography.bodySmall,
                            color = Palette.TextTertiary,
                        )
                    }
                }
                Spacer(modifier = Modifier.height(8.dp))
            }

            if (decks.isEmpty()) {
                item {
                    EmptyDecksView()
                }
            } else {
                items(decks, key = { it.id }) { deck ->
                    DeckRow(
                        deck = deck,
                        onClick = { onOpenDeck(deck.id) },
                    )
                }
            }

            item {
                Spacer(modifier = Modifier.height(24.dp))
            }
        }
    }
}

@Composable
private fun HeaderBar(onBack: () -> Unit) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 4.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        TextButton(
            onClick = onBack,
            contentPadding = androidx.compose.foundation.layout.PaddingValues(horizontal = 8.dp),
        ) {
            Text(
                text = "Chats",
                style = MaterialTheme.typography.bodyMedium,
                color = Palette.TextSecondary,
            )
            Spacer(modifier = Modifier.width(4.dp))
            Text(
                text = "/",
                style = MaterialTheme.typography.bodyMedium,
                color = Palette.TextTertiary,
            )
        }
        Spacer(modifier = Modifier.weight(1f))
        Text(
            text = "Study",
            style = MaterialTheme.typography.titleMedium,
            fontWeight = FontWeight.SemiBold,
            color = Palette.TextPrimary,
        )
        Spacer(modifier = Modifier.weight(1f))
        // Right side spacer balances the left label
        Spacer(modifier = Modifier.width(52.dp))
    }
}

@Composable
private fun ScanQuestionsCTA(
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(20.dp),
        color = Color.Transparent,
        modifier = modifier.fillMaxWidth(),
    ) {
        Column(
            modifier = Modifier.padding(vertical = 32.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // Sparkle icon in accent color
            Icon(
                imageVector = Icons.Outlined.Star,
                contentDescription = null,
                tint = Palette.Accent,
                modifier = Modifier.size(52.dp),
            )
            Spacer(modifier = Modifier.height(16.dp))
            Text(
                text = "Scan questions",
                style = MaterialTheme.typography.titleLarge.copy(
                    fontSize = 26.sp,
                    fontWeight = FontWeight.Bold,
                ),
                color = Palette.TextPrimary,
                textAlign = TextAlign.Center,
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = "Snap a page of questions to extract Q&A cards",
                style = MaterialTheme.typography.bodyMedium,
                color = Palette.TextSecondary,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(horizontal = 16.dp),
            )
        }
    }
}

@Composable
private fun GuidedLearningCTA(onClick: () -> Unit) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(16.dp),
        color = Color.Transparent,
        border = BorderStroke(1.dp, Palette.Divider),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                text = "Guided learning",
                style = MaterialTheme.typography.bodyMedium,
                fontWeight = FontWeight.Medium,
                color = Palette.TextSecondary,
                modifier = Modifier.weight(1f),
            )
            Icon(
                imageVector = Icons.Outlined.ChevronRight,
                contentDescription = null,
                tint = Palette.TextTertiary,
                modifier = Modifier.size(18.dp),
            )
        }
    }
}

@Composable
private fun EmptyDecksView() {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(top = 24.dp, bottom = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text(
            text = "No decks yet",
            style = MaterialTheme.typography.bodyMedium,
            fontWeight = FontWeight.Medium,
            color = Palette.TextSecondary,
        )
        Text(
            text = "Scan a page of questions and save the cards — they'll appear here.",
            style = MaterialTheme.typography.bodySmall,
            color = Palette.TextTertiary,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(horizontal = 24.dp),
        )
    }
}

@Composable
private fun DeckRow(
    deck: FlashcardDeck,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        shape = RoundedCornerShape(12.dp),
        color = Color.Transparent,
        border = BorderStroke(1.dp, Palette.Divider.copy(alpha = 0.6f)),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Row(
            modifier = Modifier.padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(32.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(Palette.Accent.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    imageVector = Icons.Outlined.Layers,
                    contentDescription = null,
                    tint = Palette.Accent,
                    modifier = Modifier.size(16.dp),
                )
            }

            Spacer(modifier = Modifier.width(12.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = deck.title.ifEmpty { "Untitled deck" },
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Medium,
                    color = Palette.TextPrimary,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Spacer(modifier = Modifier.height(2.dp))
                Text(
                    text = "${deck.cards.size} card${if (deck.cards.size == 1) "" else "s"} \u00b7 ${relativeTime(deck.updatedAt)}",
                    style = MaterialTheme.typography.bodySmall,
                    color = Palette.TextTertiary,
                )
            }

            Icon(
                imageVector = Icons.Outlined.ChevronRight,
                contentDescription = null,
                tint = Palette.TextTertiary,
                modifier = Modifier.size(16.dp),
            )
        }
    }
}

/** Simple relative time: just "today" / "yesterday" / "N days ago". */
private fun relativeTime(timestamp: Long): String {
    val diff = System.currentTimeMillis() - timestamp
    val days = (diff / (1000 * 60 * 60 * 24)).toInt()
    return when {
        days == 0 -> "today"
        days == 1 -> "yesterday"
        days < 7 -> "$days days ago"
        else -> SimpleDateFormat("MMM d", Locale.US).format(Date(timestamp))
    }
}
