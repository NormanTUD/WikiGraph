select 
    cat_a.name,
    cat_b.name
from 
    article_to_article art_art 
join 
    article art_a
        on art_a.id = art_art.article_from 
join 
    article art_b
        on art_b.id = art_art.article_to 
join
    article_to_category art_cat_a
        on art_cat_a.article_id = art_art.article_from 
join
    article_to_category art_cat_b
        on art_cat_b.article_id = art_art.article_from 
join
    category cat_a
        on cat_a.id = art_cat_a.category_id
join
    category cat_b
        on cat_b.id = art_cat_b.category_id
